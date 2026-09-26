-- Loyalty half-points and claimable discount vouchers.
--
-- This migration keeps the historical generic reward ledger readable, but
-- moves the active renter experience to external-admin discount offers.

-- ---------------------------------------------------------------------
-- Half-point ledger and active earning rules
-- ---------------------------------------------------------------------

create or replace function public.loyalty_user_is_eligible(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.role = 'user'
      and p.account_status = 'active'
      and public.requester_pricing_audience(p_user_id) = 'guest'
  );
$$;

revoke all on function public.loyalty_user_is_eligible(uuid) from public, anon;
grant execute on function public.loyalty_user_is_eligible(uuid) to authenticated;

drop trigger if exists reservation_requests_award_loyalty on public.reservation_requests;
drop function if exists public.award_reservation_completion_points();

alter table public.loyalty_point_rules
  drop constraint if exists loyalty_point_rules_transaction_type_check,
  drop constraint if exists loyalty_point_rules_points_check;

alter table public.loyalty_transactions
  drop constraint if exists loyalty_transactions_points_check,
  drop constraint if exists loyalty_transactions_transaction_type_check,
  drop constraint if exists loyalty_transactions_source_type_check,
  drop constraint if exists loyalty_transactions_sign,
  drop constraint if exists loyalty_transactions_source;

alter table public.loyalty_point_rules
  alter column points type numeric(10,1) using points::numeric(10,1);

alter table public.loyalty_transactions
  alter column points type numeric(10,1) using points::numeric(10,1);

delete from public.loyalty_point_rules;

alter table public.loyalty_point_rules
  add constraint loyalty_point_rules_transaction_type_check check (
    transaction_type in (
      'booking_completed',
      'booking_duration_1_to_4_hours',
      'booking_duration_5_plus_hours',
      'booking_with_amenity',
      'feedback_submitted'
    )
  ),
  add constraint loyalty_point_rules_points_check check (
    points > 0 and points * 2 = trunc(points * 2)
  );

alter table public.loyalty_transactions
  add constraint loyalty_transactions_points_check check (
    points <> 0 and abs(points) <= 100000 and points * 2 = trunc(points * 2)
  ),
  add constraint loyalty_transactions_transaction_type_check check (
    transaction_type in (
      'reservation_completed',
      'booking_completed',
      'booking_duration_1_to_4_hours',
      'booking_duration_5_plus_hours',
      'booking_with_amenity',
      'feedback_submitted',
      'reward_redeemed',
      'discount_claimed',
      'admin_adjustment'
    )
  ),
  add constraint loyalty_transactions_source_type_check check (
    source_type in (
      'reservation',
      'occurrence',
      'attendance_correction',
      'feedback',
      'redemption',
      'discount_claim',
      'discount_application',
      'admin'
    )
  ),
  add constraint loyalty_transactions_sign check (
    (transaction_type = 'reservation_completed' and points > 0)
    or (transaction_type in (
      'booking_completed',
      'booking_duration_1_to_4_hours',
      'booking_duration_5_plus_hours',
      'booking_with_amenity'
    ))
    or (transaction_type = 'feedback_submitted' and points > 0)
    or (transaction_type in ('reward_redeemed', 'discount_claimed') and points < 0)
    or transaction_type = 'admin_adjustment'
  ),
  add constraint loyalty_transactions_source check (
    transaction_type = 'admin_adjustment' or source_id is not null
  );

insert into public.loyalty_point_rules(transaction_type, points)
values
  ('booking_completed', 1.0),
  ('booking_duration_1_to_4_hours', 0.5),
  ('booking_duration_5_plus_hours', 1.0),
  ('booking_with_amenity', 0.5),
  ('feedback_submitted', 1.0);

update public.loyalty_rewards set active = false, updated_at = now();

revoke all on function public.redeem_loyalty_reward(uuid) from authenticated;
revoke all on function public.save_loyalty_reward(uuid, text, text, integer, boolean, integer) from authenticated;
revoke all on function public.set_loyalty_reward_active(uuid, boolean) from authenticated;

drop function if exists public.loyalty_points_for(text);

create or replace function public.loyalty_points_for(p_transaction_type text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select points from public.loyalty_point_rules where transaction_type = p_transaction_type;
$$;

revoke all on function public.loyalty_points_for(text) from public, anon;
grant execute on function public.loyalty_points_for(text) to authenticated;

-- ---------------------------------------------------------------------
-- Discount offer, claim, and application tables
-- ---------------------------------------------------------------------

create table if not exists public.loyalty_discount_offers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 3 and 80),
  description text not null default '' check (length(description) <= 400),
  required_points numeric(10,1) not null check (
    required_points > 0 and required_points * 2 = trunc(required_points * 2)
  ),
  discount_kind text not null check (discount_kind in ('fixed_amount', 'percentage')),
  fixed_amount_centavos integer check (fixed_amount_centavos is null or fixed_amount_centavos > 0),
  percentage numeric(5,2) check (percentage is null or percentage > 0 and percentage <= 100),
  facility_id uuid references public.facilities(id) on delete restrict,
  valid_from date not null,
  valid_until date not null,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until >= valid_from),
  check (
    (discount_kind = 'fixed_amount' and fixed_amount_centavos is not null and percentage is null)
    or (discount_kind = 'percentage' and percentage is not null and fixed_amount_centavos is null)
  )
);

create index if not exists loyalty_discount_offers_active_idx
  on public.loyalty_discount_offers(active, required_points, valid_until);
create index if not exists loyalty_discount_offers_campaign_idx
  on public.loyalty_discount_offers(valid_from, valid_until);
create index if not exists loyalty_discount_offers_facility_idx
  on public.loyalty_discount_offers(facility_id)
  where facility_id is not null;

create table if not exists public.loyalty_discount_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  offer_id uuid not null references public.loyalty_discount_offers(id) on delete restrict,
  offer_name text not null,
  offer_description text not null default '',
  discount_kind text not null check (discount_kind in ('fixed_amount', 'percentage')),
  fixed_amount_centavos integer,
  percentage numeric(5,2),
  facility_id uuid references public.facilities(id) on delete restrict,
  required_points numeric(10,1) not null check (
    required_points > 0 and required_points * 2 = trunc(required_points * 2)
  ),
  expiry_date date not null,
  points_spent numeric(10,1) not null check (
    points_spent > 0 and points_spent * 2 = trunc(points_spent * 2)
  ),
  status text not null default 'claimed' check (status in ('claimed', 'applied', 'consumed')),
  claimed_at timestamptz not null default now(),
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (discount_kind = 'fixed_amount' and fixed_amount_centavos is not null and fixed_amount_centavos > 0 and percentage is null)
    or (discount_kind = 'percentage' and percentage is not null and percentage > 0 and percentage <= 100 and fixed_amount_centavos is null)
  )
);

create index if not exists loyalty_discount_claims_user_idx
  on public.loyalty_discount_claims(user_id, status, expiry_date, claimed_at desc);
create index if not exists loyalty_discount_claims_offer_idx
  on public.loyalty_discount_claims(offer_id, claimed_at desc);

create table if not exists public.loyalty_discount_applications (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references public.loyalty_discount_claims(id) on delete restrict,
  reservation_id uuid not null references public.reservation_requests(id) on delete cascade,
  discount_amount_centavos integer not null check (discount_amount_centavos >= 0),
  status text not null default 'applied' check (status in ('applied', 'released', 'consumed')),
  applied_at timestamptz not null default now(),
  released_at timestamptz,
  consumed_at timestamptz,
  release_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists loyalty_discount_applications_active_claim_idx
  on public.loyalty_discount_applications(claim_id)
  where status = 'applied';
create unique index if not exists loyalty_discount_applications_active_reservation_idx
  on public.loyalty_discount_applications(reservation_id)
  where status = 'applied';
create index if not exists loyalty_discount_applications_reservation_idx
  on public.loyalty_discount_applications(reservation_id, status);

alter table public.reservation_requests
  add column if not exists loyalty_discount_application_id uuid
    references public.loyalty_discount_applications(id) on delete set null;

create or replace function public.touch_loyalty_discount_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  if tg_table_name = 'loyalty_discount_offers' then
    new.updated_by = auth.uid();
    if tg_op = 'INSERT' then
      new.created_by = auth.uid();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists loyalty_discount_offers_touch on public.loyalty_discount_offers;
create trigger loyalty_discount_offers_touch
before insert or update on public.loyalty_discount_offers
for each row execute function public.touch_loyalty_discount_row();

drop trigger if exists loyalty_discount_claims_touch on public.loyalty_discount_claims;
create trigger loyalty_discount_claims_touch
before update on public.loyalty_discount_claims
for each row execute function public.touch_loyalty_discount_row();

drop trigger if exists loyalty_discount_applications_touch on public.loyalty_discount_applications;
create trigger loyalty_discount_applications_touch
before update on public.loyalty_discount_applications
for each row execute function public.touch_loyalty_discount_row();

-- ---------------------------------------------------------------------
-- Loyalty earning and discount settlement helpers
-- ---------------------------------------------------------------------

create or replace function public.loyalty_audit(
  p_entity_type text,
  p_entity_id uuid,
  p_target_label text,
  p_action text,
  p_before jsonb default '{}'::jsonb,
  p_after jsonb default '{}'::jsonb,
  p_details jsonb default '{}'::jsonb,
  p_source_type text default null,
  p_source_id uuid default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
begin
  select * into actor from public.profiles where id = auth.uid();
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, before_values, after_values, details, material, source_type, source_id
  ) values (
    p_entity_type, p_entity_id, p_target_label, auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email, 'system'),
    coalesce(actor.role, 'system'),
    p_action, coalesce(p_before, '{}'::jsonb), coalesce(p_after, '{}'::jsonb),
    coalesce(p_details, '{}'::jsonb), true, p_source_type, p_source_id
  )
  on conflict (source_type, source_id) do nothing;
end;
$$;

create or replace function public.settle_loyalty_occurrence(
  p_occurrence_id uuid,
  p_outcome text,
  p_action_journal_id uuid default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_row public.reservation_occurrences%rowtype;
  request_row public.reservation_requests%rowtype;
  duration_hours numeric;
  has_amenity boolean;
  total_points numeric := 0;
  inserted_points numeric;
  source_kind text;
begin
  if p_outcome not in ('completed', 'no_show') then
    raise exception using errcode = '22023', message = 'Unknown loyalty settlement outcome';
  end if;

  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id
  for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Occurrence not found';
  end if;

  select * into request_row
  from public.reservation_requests
  where id = occurrence_row.request_id
  for update;

  if p_outcome = 'no_show'
     or request_row.requester_id is null
     or request_row.pricing_audience <> 'guest'
     or not public.loyalty_user_is_eligible(request_row.requester_id) then
    return 0;
  end if;

  duration_hours := extract(epoch from (occurrence_row.ends_at - occurrence_row.starts_at)) / 3600;
  has_amenity := exists (
      select 1 from public.reservation_amenities a where a.request_id = request_row.id
    )
    or cardinality(coalesce(request_row.amenities, '{}'::text[])) > 0;
  source_kind := case when p_action_journal_id is null then 'occurrence' else 'attendance_correction' end;

  inserted_points := null;
  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description, actor_id
  ) values (
    request_row.requester_id, public.loyalty_points_for('booking_completed'),
    'booking_completed', source_kind, coalesce(p_action_journal_id, occurrence_row.id),
    'Completed booking - ' || request_row.facility_name, auth.uid()
  )
  on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
  returning points into inserted_points;
  total_points := total_points + coalesce(inserted_points, 0);

  if duration_hours >= 5 then
    inserted_points := null;
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description, actor_id
    ) values (
      request_row.requester_id, public.loyalty_points_for('booking_duration_5_plus_hours'),
      'booking_duration_5_plus_hours', source_kind, coalesce(p_action_journal_id, occurrence_row.id),
      '5+ hour booking - ' || request_row.facility_name, auth.uid()
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
    returning points into inserted_points;
    total_points := total_points + coalesce(inserted_points, 0);
  elsif duration_hours >= 1 then
    inserted_points := null;
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description, actor_id
    ) values (
      request_row.requester_id, public.loyalty_points_for('booking_duration_1_to_4_hours'),
      'booking_duration_1_to_4_hours', source_kind, coalesce(p_action_journal_id, occurrence_row.id),
      '1-4 hour booking - ' || request_row.facility_name, auth.uid()
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
    returning points into inserted_points;
    total_points := total_points + coalesce(inserted_points, 0);
  end if;

  if has_amenity then
    inserted_points := null;
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description, actor_id
    ) values (
      request_row.requester_id, public.loyalty_points_for('booking_with_amenity'),
      'booking_with_amenity', source_kind, coalesce(p_action_journal_id, occurrence_row.id),
      'Booking with amenity - ' || request_row.facility_name, auth.uid()
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
    returning points into inserted_points;
    total_points := total_points + coalesce(inserted_points, 0);
  end if;

  if total_points > 0 then
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    values (
      request_row.requester_id, request_row.id, 'loyalty_earned',
      '+' || trim(to_char(total_points, 'FM999999990.0')) || ' points',
      'Thanks for using ' || request_row.facility_name || '.'
    );
    if p_action_journal_id is not null then
      perform public.loyalty_audit(
        'reservation', request_row.id, request_row.facility_name,
        'restored loyalty points',
        '{}'::jsonb,
        jsonb_build_object('occurrence_id', p_occurrence_id, 'points', total_points),
        '{}'::jsonb,
        'loyalty_attendance_correction',
        p_action_journal_id
      );
    end if;
  end if;

  return total_points;
end;
$$;

create or replace function public.reverse_loyalty_occurrence(
  p_occurrence_id uuid,
  p_action_journal_id uuid
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_row public.reservation_occurrences%rowtype;
  request_row public.reservation_requests%rowtype;
  original record;
  reversed_total numeric := 0;
begin
  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id
  for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Occurrence not found';
  end if;

  select * into request_row
  from public.reservation_requests
  where id = occurrence_row.request_id
  for update;

  for original in
    select transaction_type, sum(points) as points
    from public.loyalty_transactions
    where user_id = request_row.requester_id
      and source_type in ('occurrence', 'attendance_correction')
      and (
        source_id = p_occurrence_id
        or source_id in (
          select j.id
          from public.reservation_action_journal j
          where j.action = 'attendance_correction'
            and j.request_ids @> array[request_row.id]
            and j.before_occurrences @> jsonb_build_array(
              jsonb_build_object('id', p_occurrence_id)
            )
        )
      )
      and transaction_type in (
        'booking_completed',
        'booking_duration_1_to_4_hours',
        'booking_duration_5_plus_hours',
        'booking_with_amenity'
      )
    group by transaction_type
    having sum(points) > 0
  loop
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description, actor_id
    ) values (
      request_row.requester_id, -original.points, original.transaction_type,
      'attendance_correction', p_action_journal_id,
      'Attendance correction - ' || request_row.facility_name, auth.uid()
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing;
    reversed_total := reversed_total + original.points;
  end loop;

  if reversed_total > 0 then
    perform public.loyalty_audit(
      'reservation', request_row.id, request_row.facility_name,
      'reversed loyalty points',
      '{}'::jsonb,
      jsonb_build_object('occurrence_id', p_occurrence_id, 'points', -reversed_total),
      '{}'::jsonb,
      'loyalty_attendance_correction',
      p_action_journal_id
    );
  end if;

  return reversed_total;
end;
$$;

create or replace function public.settle_loyalty_discount_for_reservation(
  p_request_id uuid,
  p_outcome text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  application_row public.loyalty_discount_applications%rowtype;
  claim_row public.loyalty_discount_claims%rowtype;
  has_terminal_use boolean;
begin
  select * into application_row
  from public.loyalty_discount_applications
  where reservation_id = p_request_id and status = 'applied'
  for update;
  if application_row.id is null then
    return;
  end if;

  select * into claim_row
  from public.loyalty_discount_claims
  where id = application_row.claim_id
  for update;

  if p_outcome = 'consume' then
    update public.loyalty_discount_applications
    set status = 'consumed', consumed_at = now()
    where id = application_row.id;
    update public.loyalty_discount_claims
    set status = 'consumed', consumed_at = now()
    where id = claim_row.id;
    perform public.loyalty_audit(
      'reservation', p_request_id, claim_row.offer_name,
      'consumed a loyalty discount voucher',
      '{}'::jsonb, to_jsonb(application_row), '{}'::jsonb,
      'loyalty_discount_application', application_row.id
    );
    return;
  end if;

  if p_outcome = 'release' then
    select exists (
      select 1 from public.reservation_occurrences
      where request_id = p_request_id
        and lifecycle_stage in ('completed', 'no_show')
    ) into has_terminal_use;
    if has_terminal_use then
      perform public.settle_loyalty_discount_for_reservation(p_request_id, 'consume', p_reason);
      return;
    end if;
    update public.loyalty_discount_applications
    set status = 'released', released_at = now(), release_reason = nullif(trim(p_reason), '')
    where id = application_row.id;
    update public.loyalty_discount_claims
    set status = 'claimed'
    where id = claim_row.id;
    perform public.loyalty_audit(
      'reservation', p_request_id, claim_row.offer_name,
      'released a loyalty discount voucher',
      '{}'::jsonb,
      jsonb_build_object('claim_id', claim_row.id, 'reason', p_reason),
      '{}'::jsonb,
      'loyalty_discount_application',
      application_row.id
    );
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Offer management and renter summary/claim RPCs
-- ---------------------------------------------------------------------

create or replace function public.save_loyalty_discount_offer(
  p_id uuid default null,
  p_name text default null,
  p_description text default '',
  p_required_points numeric default null,
  p_discount_kind text default null,
  p_fixed_amount_centavos integer default null,
  p_percentage numeric default null,
  p_facility_id uuid default null,
  p_valid_from date default null,
  p_valid_until date default null,
  p_active boolean default true
) returns public.loyalty_discount_offers
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.loyalty_discount_offers%rowtype;
  result public.loyalty_discount_offers%rowtype;
  clean_name text := trim(coalesce(p_name, ''));
  clean_description text := trim(coalesce(p_description, ''));
  has_claims boolean := false;
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  if length(clean_name) not between 3 and 80 then
    raise exception using errcode = '22023', message = 'Discount name must be between 3 and 80 characters';
  end if;
  if length(clean_description) > 400 then
    raise exception using errcode = '22023', message = 'Description must be 400 characters or fewer';
  end if;
  if p_required_points is null or p_required_points <= 0
     or p_required_points * 2 <> trunc(p_required_points * 2) then
    raise exception using errcode = '22023', message = 'Points required must be a positive multiple of 0.5';
  end if;
  if p_discount_kind not in ('fixed_amount', 'percentage') then
    raise exception using errcode = '22023', message = 'Choose a discount type';
  end if;
  if p_discount_kind = 'fixed_amount'
     and (coalesce(p_fixed_amount_centavos, 0) <= 0 or p_percentage is not null) then
    raise exception using errcode = '22023', message = 'Fixed discounts need a positive PHP amount';
  end if;
  if p_discount_kind = 'percentage'
     and (p_percentage is null or p_percentage <= 0 or p_percentage > 100 or p_fixed_amount_centavos is not null) then
    raise exception using errcode = '22023', message = 'Percentage discounts must be between 0 and 100';
  end if;
  if p_valid_from is null or p_valid_until is null or p_valid_until < p_valid_from then
    raise exception using errcode = '22023', message = 'Choose a valid campaign date range';
  end if;
  if p_facility_id is not null and not exists (
    select 1 from public.facilities where id = p_facility_id and archived_at is null
  ) then
    raise exception using errcode = '22023', message = 'Facility not found';
  end if;

  if p_id is null then
    insert into public.loyalty_discount_offers(
      name, description, required_points, discount_kind, fixed_amount_centavos,
      percentage, facility_id, valid_from, valid_until, active
    ) values (
      clean_name, clean_description, p_required_points::numeric(10,1), p_discount_kind,
      case when p_discount_kind = 'fixed_amount' then p_fixed_amount_centavos else null end,
      case when p_discount_kind = 'percentage' then p_percentage::numeric(5,2) else null end,
      p_facility_id, p_valid_from, p_valid_until, coalesce(p_active, true)
    ) returning * into result;
    perform public.loyalty_audit(
      'system', result.id, result.name, 'created a loyalty discount offer',
      '{}'::jsonb, to_jsonb(result), '{}'::jsonb, 'loyalty_discount_offer', result.id
    );
  else
    select * into existing
    from public.loyalty_discount_offers
    where id = p_id
    for update;
    if existing.id is null then
      raise exception using errcode = 'P0002', message = 'Discount offer not found';
    end if;
    select exists (
      select 1 from public.loyalty_discount_claims where offer_id = p_id
    ) into has_claims;
    if has_claims and (
      existing.required_points is distinct from p_required_points::numeric(10,1)
      or existing.discount_kind is distinct from p_discount_kind
      or existing.fixed_amount_centavos is distinct from case when p_discount_kind = 'fixed_amount' then p_fixed_amount_centavos else null end
      or existing.percentage is distinct from case when p_discount_kind = 'percentage' then p_percentage::numeric(5,2) else null end
      or existing.facility_id is distinct from p_facility_id
    ) then
      raise exception using errcode = '22023',
        message = 'Create a new offer to change discount terms after vouchers have been claimed';
    end if;

    update public.loyalty_discount_offers
    set name = clean_name,
        description = clean_description,
        required_points = p_required_points::numeric(10,1),
        discount_kind = p_discount_kind,
        fixed_amount_centavos = case when p_discount_kind = 'fixed_amount' then p_fixed_amount_centavos else null end,
        percentage = case when p_discount_kind = 'percentage' then p_percentage::numeric(5,2) else null end,
        facility_id = p_facility_id,
        valid_from = p_valid_from,
        valid_until = p_valid_until,
        active = coalesce(p_active, active)
    where id = p_id
    returning * into result;
    perform public.loyalty_audit(
      'system', result.id, result.name, 'updated a loyalty discount offer',
      to_jsonb(existing), to_jsonb(result), '{}'::jsonb,
      'loyalty_discount_offer', gen_random_uuid()
    );
  end if;

  return result;
end;
$$;

create or replace function public.set_loyalty_discount_offer_active(
  p_offer_id uuid,
  p_active boolean
) returns public.loyalty_discount_offers
language plpgsql
security definer
set search_path = public
as $$
declare
  existing public.loyalty_discount_offers%rowtype;
  result public.loyalty_discount_offers%rowtype;
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  select * into existing from public.loyalty_discount_offers where id = p_offer_id for update;
  if existing.id is null then
    raise exception using errcode = 'P0002', message = 'Discount offer not found';
  end if;
  update public.loyalty_discount_offers
  set active = coalesce(p_active, false)
  where id = p_offer_id
  returning * into result;
  perform public.loyalty_audit(
    'system', result.id, result.name,
    case when result.active then 'activated a loyalty discount offer' else 'deactivated a loyalty discount offer' end,
    to_jsonb(existing), to_jsonb(result), '{}'::jsonb,
    'loyalty_discount_offer', gen_random_uuid()
  );
  return result;
end;
$$;

create or replace function public.loyalty_discount_offer_admin_list()
returns setof public.loyalty_discount_offers
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  return query
  select * from public.loyalty_discount_offers
  order by active desc, valid_until desc, required_points, name;
end;
$$;

create or replace function public.claim_loyalty_discount(p_offer_id uuid)
returns public.loyalty_discount_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  offer public.loyalty_discount_offers%rowtype;
  claim public.loyalty_discount_claims%rowtype;
  balance numeric;
  today date := (now() at time zone 'Asia/Manila')::date;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  perform 1 from public.profiles where id = auth.uid() for update;
  if not public.loyalty_user_is_eligible(auth.uid()) then
    raise exception using errcode = '42501', message = 'Loyalty discounts are available to guest renters only';
  end if;

  select * into offer
  from public.loyalty_discount_offers
  where id = p_offer_id
  for update;
  if offer.id is null or not offer.active then
    raise exception using errcode = '22023', message = 'This discount is not available';
  end if;
  if today < offer.valid_from or today > offer.valid_until then
    raise exception using errcode = '22023', message = 'This discount campaign is not active';
  end if;

  select coalesce(sum(points), 0) into balance
  from public.loyalty_transactions
  where user_id = auth.uid();
  if balance < offer.required_points then
    raise exception using errcode = '22023',
      message = 'You need ' || trim(to_char(offer.required_points - balance, 'FM999999990.0')) || ' more points for this discount';
  end if;

  insert into public.loyalty_discount_claims(
    user_id, offer_id, offer_name, offer_description, discount_kind,
    fixed_amount_centavos, percentage, facility_id, required_points,
    expiry_date, points_spent
  ) values (
    auth.uid(), offer.id, offer.name, offer.description, offer.discount_kind,
    offer.fixed_amount_centavos, offer.percentage, offer.facility_id,
    offer.required_points, offer.valid_until, offer.required_points
  ) returning * into claim;

  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description
  ) values (
    auth.uid(), -offer.required_points, 'discount_claimed', 'discount_claim',
    claim.id, 'Claimed discount - ' || offer.name
  );

  perform public.loyalty_audit(
    'account', auth.uid(), offer.name, 'claimed a loyalty discount voucher',
    '{}'::jsonb, to_jsonb(claim), '{}'::jsonb, 'loyalty_discount_claim', claim.id
  );

  insert into public.app_notifications(recipient_id, kind, title, body)
  values (
    auth.uid(), 'loyalty_redeemed', 'Discount claimed',
    offer.name || ' is ready for one future booking.'
  );

  return claim;
end;
$$;

drop function if exists public.loyalty_balance(uuid);

create or replace function public.loyalty_balance(p_user_id uuid default auth.uid())
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_user_id <> auth.uid() and not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Not authorized to view this balance';
  end if;
  if not public.loyalty_user_is_eligible(p_user_id) then
    return 0;
  end if;
  return coalesce(
    (select sum(points) from public.loyalty_transactions where user_id = p_user_id), 0
  );
end;
$$;

create or replace function public.loyalty_my_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  eligible boolean;
  balance_value numeric;
  today date := (now() at time zone 'Asia/Manila')::date;
  result_value jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  eligible := public.loyalty_user_is_eligible(auth.uid());
  if not eligible then
    return jsonb_build_object(
      'eligible', false,
      'balance', 0,
      'lifetime_earned', 0,
      'lifetime_redeemed', 0,
      'rules', '{}'::jsonb,
      'transactions', '[]'::jsonb,
      'redemptions', '[]'::jsonb,
      'rewards', '[]'::jsonb,
      'offers', '[]'::jsonb,
      'claims', '[]'::jsonb
    );
  end if;

  select coalesce(sum(points), 0) into balance_value
  from public.loyalty_transactions
  where user_id = auth.uid();

  select jsonb_build_object(
    'eligible', true,
    'balance', balance_value,
    'lifetime_earned', coalesce((select sum(points) from public.loyalty_transactions where user_id = auth.uid() and points > 0), 0),
    'lifetime_redeemed', coalesce((select sum(-points) from public.loyalty_transactions where user_id = auth.uid() and points < 0), 0),
    'rules', (select coalesce(jsonb_object_agg(transaction_type, points), '{}'::jsonb) from public.loyalty_point_rules),
    'transactions', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.created_at desc)
      from (
        select * from public.loyalty_transactions
        where user_id = auth.uid()
        order by created_at desc
        limit 50
      ) t
    ), '[]'::jsonb),
    'redemptions', '[]'::jsonb,
    'rewards', '[]'::jsonb,
    'offers', coalesce((
      select jsonb_agg(
        to_jsonb(o)
        || jsonb_build_object(
          'facility_name', f.name,
          'affordable', balance_value >= o.required_points
        )
        order by o.required_points, o.valid_until, o.name
      )
      from public.loyalty_discount_offers o
      left join public.facilities f on f.id = o.facility_id
      where o.active
        and today between o.valid_from and o.valid_until
    ), '[]'::jsonb),
    'claims', coalesce((
      select jsonb_agg(
        to_jsonb(c)
        || jsonb_build_object(
          'effective_status',
          case when c.status <> 'consumed' and c.expiry_date < today then 'expired' else c.status end,
          'facility_name', f.name,
          'application', (
            select to_jsonb(a) || jsonb_build_object('reservation_id', a.reservation_id)
            from public.loyalty_discount_applications a
            where a.claim_id = c.id
            order by a.applied_at desc
            limit 1
          )
        )
        order by c.claimed_at desc
      )
      from public.loyalty_discount_claims c
      left join public.facilities f on f.id = c.facility_id
      where c.user_id = auth.uid()
      limit 50
    ), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

drop function if exists public.loyalty_admin_balances(text, integer);

create or replace function public.loyalty_admin_balances(
  p_search text default null,
  p_limit integer default 100
) returns table(
  user_id uuid, full_name text, email text, balance numeric,
  lifetime_earned numeric, lifetime_redeemed numeric, last_activity_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  return query
  select p.id, p.full_name, p.email,
    coalesce(sum(t.points), 0),
    coalesce(sum(t.points) filter (where t.points > 0), 0),
    coalesce(sum(-t.points) filter (where t.points < 0), 0),
    max(t.created_at)
  from public.profiles p
  left join public.loyalty_transactions t on t.user_id = p.id
  where public.loyalty_user_is_eligible(p.id)
    and (nullif(trim(p_search), '') is null
      or p.full_name ilike '%' || trim(p_search) || '%'
      or p.email ilike '%' || trim(p_search) || '%')
  group by p.id, p.full_name, p.email
  order by coalesce(sum(t.points), 0) desc, p.full_name
  limit p_limit;
end;
$$;

drop function if exists public.adjust_loyalty_points(uuid, integer, text);

create or replace function public.adjust_loyalty_points(
  p_user_id uuid,
  p_points numeric,
  p_reason text
) returns public.loyalty_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  ledger public.loyalty_transactions%rowtype;
  balance numeric;
  clean_reason text;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_points is null or p_points = 0 or p_points * 2 <> trunc(p_points * 2) then
    raise exception using errcode = '22023', message = 'Enter a nonzero half-point amount';
  end if;
  clean_reason := trim(coalesce(p_reason, ''));
  if clean_reason = '' then
    raise exception using errcode = '22023', message = 'A reason is required for a manual adjustment';
  end if;

  select * into actor from public.profiles where id = auth.uid();
  perform 1 from public.profiles where id = p_user_id for update;
  select * into target from public.profiles where id = p_user_id;
  if target.id is null then
    raise exception using errcode = 'P0002', message = 'User not found';
  end if;
  if not public.loyalty_user_is_eligible(p_user_id) then
    raise exception using errcode = '42501', message = 'Loyalty adjustments are limited to guest renters';
  end if;

  select coalesce(sum(points), 0) into balance
  from public.loyalty_transactions where user_id = p_user_id;
  if balance + p_points < 0 then
    raise exception using errcode = '22023', message = 'This adjustment would take the balance below zero';
  end if;

  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description, actor_id
  ) values (
    p_user_id, p_points::numeric(10,1), 'admin_adjustment', 'admin', gen_random_uuid(),
    'Admin adjustment: ' || clean_reason, auth.uid()
  ) returning * into ledger;

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, after_values, material, source_type, source_id
  ) values (
    'account', p_user_id, coalesce(nullif(target.full_name, ''), target.email),
    auth.uid(), coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    'adjusted loyalty points', clean_reason,
    jsonb_build_object('points', p_points, 'balance', balance + p_points),
    true, 'loyalty_adjustment', ledger.id
  );

  insert into public.app_notifications(recipient_id, kind, title, body)
  values (
    p_user_id, 'loyalty_earned',
    (case when p_points > 0 then '+' else '' end) || trim(to_char(p_points, 'FM999999990.0')) || ' points',
    'Admin adjustment: ' || clean_reason
  );

  return ledger;
end;
$$;

revoke all on function public.adjust_loyalty_points(uuid, numeric, text) from public, anon;
grant execute on function public.adjust_loyalty_points(uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------
-- Quote and submission with optional discount claim
-- ---------------------------------------------------------------------

drop function if exists public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer);

create or replace function public.get_reservation_quote(
  p_facility_id uuid,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],
  p_headcount integer default null,
  p_discount_claim_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  facility public.facilities%rowtype;
  claim public.loyalty_discount_claims%rowtype;
  audience_value text;
  lane_value text;
  exemption_value text;
  rate_value integer;
  facility_total integer := 0;
  amenity_total integer := 0;
  discount_total integer := 0;
  subtotal_value integer := 0;
  total_value integer;
  total_minutes numeric := 0;
  lines_value jsonb := '[]'::jsonb;
  amenities_value jsonb := '[]'::jsonb;
  terms_value jsonb := '[]'::jsonb;
  discount_value jsonb := null;
  payload jsonb;
  item record;
  local_start timestamp;
  local_end timestamp;
  i integer;
  today date := (now() at time zone 'Asia/Manila')::date;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing
    and status = 'active';
  if facility.id is null then
    raise exception using errcode = 'P0002', message = 'Facility not found or unavailable';
  end if;
  audience_value := public.requester_pricing_audience();
  lane_value := public.requester_admin_lane();
  exemption_value := case audience_value
    when 'student' then 'verified_student'
    when 'faculty' then 'verified_faculty'
    else 'none'
  end;
  if facility.facility_classification not in ('shared', lane_value) then
    raise exception using errcode = '22023',
      message = 'This facility is not available for your account type';
  end if;
  if not public.has_active_admin_in_lane(lane_value) then
    raise exception using errcode = '22023',
      message = 'This facility does not yet have an administrator for your account type';
  end if;
  if cardinality(p_starts_at) is null or cardinality(p_starts_at) not between 1 and 12
     or cardinality(p_starts_at) <> cardinality(p_ends_at) then
    raise exception using errcode = '22023', message = 'Provide between one and twelve valid occurrences';
  end if;
  if p_headcount is not null and p_headcount not between 1 and facility.capacity then
    raise exception using errcode = '22023', message = 'Attendee count exceeds facility capacity';
  end if;
  if exemption_value = 'none' then
    select hourly_rate_centavos into rate_value
    from public.facility_rates
    where facility_id = p_facility_id and audience = audience_value and enabled;
    if rate_value is null then
      raise exception using errcode = '22023', message = 'No active rate is configured for your account type';
    end if;
  else
    rate_value := 0;
  end if;
  for i in 1..cardinality(p_starts_at) loop
    local_start := p_starts_at[i] at time zone 'Asia/Manila';
    local_end := p_ends_at[i] at time zone 'Asia/Manila';
    if p_starts_at[i] >= p_ends_at[i] or local_start::date <> local_end::date then
      raise exception using errcode = '22023', message = 'Choose a valid same-day time range';
    end if;
    if not facility.open_days[extract(isodow from local_start)::integer]
       or local_start::time < facility.open_time or local_end::time > facility.close_time then
      raise exception using errcode = '22023', message = 'Reservation is outside facility operating hours';
    end if;
    if extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60
        > facility.max_duration_minutes then
      raise exception using errcode = '22023', message = 'Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now()
       or p_starts_at[i] > now() + make_interval(days => facility.advance_booking_days) then
      raise exception using errcode = '22023', message = 'Reservation date is outside the booking window';
    end if;
    total_minutes := total_minutes + extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60;
  end loop;
  facility_total := round(total_minutes * rate_value / 60)::integer;
  lines_value := jsonb_build_array(jsonb_build_object(
    'line_type','facility','source_id',facility.id,'label',facility.name::text,
    'quantity',round(total_minutes / 60, 2),'unit_amount_centavos',rate_value,
    'line_total_centavos',facility_total
  ));
  if cardinality(coalesce(p_amenity_ids, '{}'::uuid[]))
      <> cardinality(array(
        select distinct amenity_id
        from unnest(coalesce(p_amenity_ids, '{}'::uuid[])) amenity_id
      )) then
    raise exception using errcode = '22023', message = 'Duplicate amenities are not allowed';
  end if;
  for item in
    select a.*,
      case a.pricing_unit when 'per_occurrence' then cardinality(p_starts_at) else 1 end quantity_value
    from public.facility_amenities a
    where a.id = any(coalesce(p_amenity_ids, '{}'::uuid[]))
      and a.facility_id = p_facility_id and a.enabled
    order by a.name
  loop
    declare
      unit_price integer := case when exemption_value = 'none'
        then item.price_centavos else 0 end;
      line_total integer := unit_price * item.quantity_value;
    begin
      amenity_total := amenity_total + line_total;
      amenities_value := amenities_value || jsonb_build_array(jsonb_build_object(
        'id',item.id,'name',item.name::text,'price_centavos',unit_price,
        'quantity',item.quantity_value,'line_total_centavos',line_total
      ));
      lines_value := lines_value || jsonb_build_array(jsonb_build_object(
        'line_type','amenity','source_id',item.id,'label',item.name::text,
        'quantity',item.quantity_value,'unit_amount_centavos',unit_price,
        'line_total_centavos',line_total
      ));
    end;
  end loop;
  if jsonb_array_length(amenities_value) <> cardinality(coalesce(p_amenity_ids, '{}'::uuid[])) then
    raise exception using errcode = '22023', message = 'One or more amenities are unavailable for this facility';
  end if;
  subtotal_value := facility_total + amenity_total;

  if p_discount_claim_id is not null then
    if audience_value <> 'guest' or not public.loyalty_user_is_eligible(auth.uid()) then
      raise exception using errcode = '42501', message = 'Loyalty discounts are available to guest renters only';
    end if;
    select * into claim
    from public.loyalty_discount_claims
    where id = p_discount_claim_id and user_id = auth.uid();
    if claim.id is null then
      raise exception using errcode = '22023', message = 'Discount voucher not found';
    end if;
    if claim.status <> 'claimed' then
      raise exception using errcode = '22023', message = 'This voucher is already in use';
    end if;
    if claim.expiry_date < today then
      raise exception using errcode = '22023', message = 'This voucher has expired';
    end if;
    if claim.facility_id is not null and claim.facility_id <> p_facility_id then
      raise exception using errcode = '22023', message = 'This voucher cannot be used for this facility';
    end if;

    discount_total := case claim.discount_kind
      when 'fixed_amount' then least(coalesce(claim.fixed_amount_centavos, 0), subtotal_value)
      else round(subtotal_value::numeric * coalesce(claim.percentage, 0) / 100)::integer
    end;
    discount_total := least(greatest(discount_total, 0), subtotal_value);
    discount_value := jsonb_build_object(
      'claim_id', claim.id,
      'offer_name', claim.offer_name,
      'discount_kind', claim.discount_kind,
      'fixed_amount_centavos', claim.fixed_amount_centavos,
      'percentage', claim.percentage,
      'discount_amount_centavos', discount_total,
      'expiry_date', claim.expiry_date,
      'facility_id', claim.facility_id
    );
    if discount_total > 0 then
      lines_value := lines_value || jsonb_build_array(jsonb_build_object(
        'line_type','discount','source_id',claim.id,'label',claim.offer_name,
        'quantity',1,'unit_amount_centavos',-discount_total,
        'line_total_centavos',-discount_total
      ));
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'title',t.title,'version',t.version,'content',t.content,
    'content_hash',t.content_hash
  ) order by t.scope,t.version),'[]'::jsonb)
  into terms_value
  from public.terms_versions t
  where t.active and (t.scope = 'global' or t.facility_id = p_facility_id);
  total_value := subtotal_value - discount_total;
  payload := jsonb_build_object(
    'facility_id',facility.id,'audience',audience_value,'admin_lane',lane_value,
    'currency','PHP','facility_amount_centavos',facility_total,
    'amenity_amount_centavos',amenity_total,'discount_amount_centavos',discount_total,
    'discount', discount_value,
    'discount_claim_id', p_discount_claim_id,
    'total_amount_centavos',total_value,
    'down_payment_percent',facility.down_payment_percent,
    'payment_exemption',exemption_value,
    'required_down_payment_centavos',
      (total_value * facility.down_payment_percent + 99) / 100,
    'lines',lines_value,'amenities',amenities_value,'terms',terms_value
  );
  return payload || jsonb_build_object(
    'pricing_fingerprint', encode(extensions.digest(payload::text, 'sha256'), 'hex')
  );
end;
$$;

revoke all on function public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer,uuid)
  from public, anon;
grant execute on function public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer,uuid)
  to authenticated;

drop function if exists public.submit_reservation_v2(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], uuid[], uuid[], text, jsonb, text[]
);

create or replace function public.submit_reservation_v2(
  p_request_id uuid,
  p_facility_id uuid,
  p_purpose text,
  p_headcount integer,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],
  p_terms_version_ids uuid[] default '{}'::uuid[],
  p_pricing_fingerprint text default null,
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_requested_amenities text[] default '{}'::text[],
  p_discount_claim_id uuid default null
) returns public.reservation_requests
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  profile public.profiles%rowtype;
  facility public.facilities%rowtype;
  claim public.loyalty_discount_claims%rowtype;
  quote jsonb;
  result public.reservation_requests%rowtype;
  application_id uuid;
  attachment jsonb;
  line jsonb;
  amenity jsonb;
  term_row public.terms_versions%rowtype;
  required_terms uuid[];
  selected_names text[];
  requested_names text[];
  lane_value text;
  allowed_catalog text[] := array[
    'Wi-Fi',
    'Power Outlets',
    'Air Conditioning',
    'Projector',
    'Smart TV',
    'Sound System',
    'Whiteboard',
    'Parking',
    'PWD Accessibility',
    'Security Cameras',
    'Generator'
  ];
  invalid_requested text;
  local_start timestamp;
  local_end timestamp;
  event_id uuid;
  i integer;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Sign in required'; end if;
  select * into profile from public.profiles where id = auth.uid() for update;
  if profile.id is null or profile.account_status <> 'active' or profile.role <> 'user' then
    raise exception using errcode='42501',message='This account cannot submit reservations';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing and status = 'active'
  for share;
  if facility.id is null then raise exception using errcode='P0002',message='Facility not found or unavailable'; end if;
  lane_value := public.requester_admin_lane(profile.id);
  if facility.facility_classification not in ('shared', lane_value) then
    raise exception using errcode='22023',
      message='This facility is not available for your account type';
  end if;
  if not public.has_active_admin_in_lane(lane_value) then
    raise exception using errcode='22023',
      message='This facility does not yet have an administrator for your account type';
  end if;
  if p_discount_claim_id is not null then
    select * into claim
    from public.loyalty_discount_claims
    where id = p_discount_claim_id
    for update;
    if claim.id is null or claim.user_id <> auth.uid() or claim.status <> 'claimed' then
      raise exception using errcode='22023', message='This voucher is not available';
    end if;
  end if;
  perform 1 from public.facility_rates
    where facility_id = p_facility_id and enabled for share;
  perform 1 from public.facility_amenities
    where id = any(coalesce(p_amenity_ids,'{}'::uuid[])) for share;
  perform 1 from public.terms_versions
    where active and (scope='global' or facility_id=p_facility_id) for share;

  select requested.value into invalid_requested
  from unnest(coalesce(p_requested_amenities,'{}'::text[])) requested(value)
  where trim(coalesce(requested.value,'')) <> ''
    and not exists (
      select 1
      from unnest(allowed_catalog) allowed(label)
      where lower(allowed.label) = lower(trim(requested.value))
    )
  limit 1;
  if invalid_requested is not null then
    raise exception using errcode='22023',
      message='One or more requested amenities are not in the standard catalog';
  end if;

  select coalesce(array_agg(allowed.label order by allowed.ord),'{}'::text[])
  into requested_names
  from unnest(allowed_catalog) with ordinality allowed(label, ord)
  where exists (
      select 1
      from unnest(coalesce(p_requested_amenities,'{}'::text[])) requested(value)
      where lower(trim(requested.value)) = lower(allowed.label)
    )
    and not exists (
      select 1
      from unnest(coalesce(facility.amenities,'{}'::text[])) included(label)
      where lower(trim(included.label)) = lower(allowed.label)
    );

  quote := public.get_reservation_quote(
    p_facility_id,p_starts_at,p_ends_at,p_amenity_ids,p_headcount,p_discount_claim_id
  );
  if p_pricing_fingerprint is null
     or p_pricing_fingerprint <> quote->>'pricing_fingerprint' then
    raise exception using errcode='40001',message='Pricing changed. Review the updated quote and try again';
  end if;
  if p_headcount not between 1 and facility.capacity then
    raise exception using errcode='22023',message='Attendee count exceeds facility capacity';
  end if;
  if length(trim(p_purpose)) not between 3 and 1000 then
    raise exception using errcode='22023',message='Provide a reservation purpose';
  end if;
  if jsonb_array_length(coalesce(p_attachment_metadata,'[]'::jsonb)) > 3 then
    raise exception using errcode='22023',message='A maximum of three supporting files is allowed';
  end if;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into required_terms
  from public.terms_versions
  where active and (scope='global' or facility_id=p_facility_id);
  if cardinality(required_terms) <> cardinality(array(
      select distinct id from unnest(coalesce(p_terms_version_ids,'{}'::uuid[])) id
    )) or not required_terms @> coalesce(p_terms_version_ids,'{}'::uuid[]) then
    raise exception using errcode='22023',message='Accept the current reservation terms before submitting';
  end if;
  for i in 1..cardinality(p_starts_at) loop
    local_start := p_starts_at[i] at time zone 'Asia/Manila';
    local_end := p_ends_at[i] at time zone 'Asia/Manila';
    if p_starts_at[i] >= p_ends_at[i] or local_start::date <> local_end::date then
      raise exception using errcode='22023',message='Choose a valid same-day time range';
    end if;
    if not facility.open_days[extract(isodow from local_start)::integer]
       or local_start::time < facility.open_time or local_end::time > facility.close_time then
      raise exception using errcode='22023',message='Reservation is outside facility operating hours';
    end if;
    if extract(epoch from (p_ends_at[i]-p_starts_at[i]))/60 > facility.max_duration_minutes then
      raise exception using errcode='22023',message='Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now()
       or p_starts_at[i] > now()+make_interval(days=>facility.advance_booking_days) then
      raise exception using errcode='22023',message='Reservation date is outside the booking window';
    end if;
  end loop;
  select coalesce(array_agg(a.name::text order by a.name),'{}'::text[])
  into selected_names
  from public.facility_amenities a
  where a.id=any(coalesce(p_amenity_ids,'{}'::uuid[]));
  insert into public.reservation_requests(
    id,requester_id,facility_id,requester_name,requester_role,requester_unit,
    facility_name,facility_building,facility_room,facility_capacity,purpose,headcount,
    status,held_for_verification,recurrence,payment_amount_centavos,payment_status,
    amenities,admin_lane,pricing_audience,currency,facility_amount_centavos,
    amenity_amount_centavos,discount_amount_centavos,total_amount_centavos,
    required_down_payment_centavos,pricing_fingerprint,down_payment_percent,
    payment_exemption
  ) values (
    p_request_id,profile.id,facility.id,coalesce(nullif(profile.full_name,''),profile.email),
    profile.role,coalesce(profile.unit,''),facility.name::text,facility.building,facility.room,
    facility.capacity,trim(p_purpose),p_headcount,'pending',false,
    case when cardinality(p_starts_at)>1 then 'weekly' else 'none' end,
    (quote->>'total_amount_centavos')::integer,
    case when (quote->>'total_amount_centavos')::integer=0 then 'not_required' else 'quoted' end,
    selected_names || requested_names,quote->>'admin_lane',quote->>'audience','PHP',
    (quote->>'facility_amount_centavos')::integer,
    (quote->>'amenity_amount_centavos')::integer,
    (quote->>'discount_amount_centavos')::integer,
    (quote->>'total_amount_centavos')::integer,
    (quote->>'required_down_payment_centavos')::integer,
    quote->>'pricing_fingerprint',
    (quote->>'down_payment_percent')::integer,
    quote->>'payment_exemption'
  ) returning * into result;

  if p_discount_claim_id is not null then
    insert into public.loyalty_discount_applications(
      claim_id, reservation_id, discount_amount_centavos, status
    ) values (
      p_discount_claim_id, result.id, (quote->>'discount_amount_centavos')::integer, 'applied'
    ) returning id into application_id;
    update public.loyalty_discount_claims
    set status = 'applied'
    where id = p_discount_claim_id;
    update public.reservation_requests
    set loyalty_discount_application_id = application_id
    where id = result.id
    returning * into result;
    perform public.loyalty_audit(
      'reservation', result.id, claim.offer_name,
      'applied a loyalty discount voucher',
      '{}'::jsonb,
      jsonb_build_object('claim_id', p_discount_claim_id, 'application_id', application_id, 'discount_amount_centavos', quote->>'discount_amount_centavos'),
      '{}'::jsonb,
      'loyalty_discount_application',
      application_id
    );
  end if;

  for i in 1..cardinality(p_starts_at) loop
    insert into public.reservation_occurrences(
      request_id,facility_id,starts_at,ends_at,buffer_minutes
    ) values (result.id,facility.id,p_starts_at[i],p_ends_at[i],facility.booking_buffer_minutes);
  end loop;
  for amenity in select value from jsonb_array_elements(quote->'amenities') loop
    insert into public.reservation_amenities(
      request_id,facility_amenity_id,name_snapshot,unit_price_centavos,quantity,line_total_centavos
    ) values (
      result.id,(amenity->>'id')::uuid,amenity->>'name',
      (amenity->>'price_centavos')::integer,(amenity->>'quantity')::integer,
      (amenity->>'line_total_centavos')::integer
    );
  end loop;
  for line in select value from jsonb_array_elements(quote->'lines') loop
    insert into public.reservation_price_lines(
      request_id,line_type,source_id,label,quantity,unit_amount_centavos,line_total_centavos
    ) values (
      result.id,line->>'line_type',
      case when line->>'line_type' = 'discount' then application_id else (line->>'source_id')::uuid end,
      line->>'label',
      (line->>'quantity')::numeric,(line->>'unit_amount_centavos')::integer,
      (line->>'line_total_centavos')::integer
    );
  end loop;
  for term_row in select * from public.terms_versions where id=any(required_terms) loop
    insert into public.reservation_terms_acceptances(
      request_id,terms_version_id,user_id,content_hash
    ) values (result.id,term_row.id,profile.id,term_row.content_hash);
  end loop;
  for attachment in select value from jsonb_array_elements(coalesce(p_attachment_metadata,'[]'::jsonb)) loop
    if attachment->>'storage_path' not like auth.uid()::text||'/%' then
      raise exception using errcode='42501',message='Invalid attachment path';
    end if;
    insert into public.reservation_attachments(
      request_id,owner_id,storage_path,file_name,mime_type,byte_size
    ) values (
      result.id,auth.uid(),attachment->>'storage_path',attachment->>'file_name',
      attachment->>'mime_type',(attachment->>'byte_size')::integer
    );
  end loop;
  event_id := public.reservation_event(result.id,'submitted a reservation request',null,
    jsonb_build_object('admin_lane',result.admin_lane,'total_amount_centavos',result.total_amount_centavos),null,false);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select p.id,result.id,event_id,'reservation_submitted','New reservation request',
    result.requester_name||' requested '||result.facility_name
  from public.profiles p
  where p.account_status='active'
    and p.role=case result.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
end;
$$;

revoke all on function public.submit_reservation_v2(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], uuid[], uuid[], text, jsonb, text[], uuid
) from public, anon, authenticated;
grant execute on function public.submit_reservation_v2(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], uuid[], uuid[], text, jsonb, text[], uuid
) to authenticated;

-- ---------------------------------------------------------------------
-- Attendance, feedback, and terminal lifecycle overrides
-- ---------------------------------------------------------------------

create or replace function public.record_occurrence_attendance(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_action text,
  p_reason text default null,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
  event_id uuid;
  target_stage text;
  now_version integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_action not in ('check_in', 'complete', 'no_show') then
    raise exception using errcode = '22023', message = 'Unknown attendance action';
  end if;
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> p_action or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023',
        message = 'That attendance key was already used for another action';
    end if;
    return jsonb_build_object('duplicate', true, 'action_id', null, 'undo_until', null);
  end if;

  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed reservation can enter facility use';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;

  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null or occurrence_row.booking_state <> 'booked' then
    raise exception using errcode = '22023', message = 'This occurrence is not booked';
  end if;
  if p_action = 'check_in' and now() < occurrence_row.starts_at - interval '30 minutes' then
    raise exception using errcode = '22023', message = 'Check-in opens 30 minutes before the booking';
  end if;
  if p_action = 'complete' and occurrence_row.lifecycle_stage <> 'checked_in' then
    raise exception using errcode = '22023', message = 'Check in before completing this booking';
  end if;
  if p_action = 'no_show' and now() < occurrence_row.starts_at + interval '15 minutes' then
    raise exception using errcode = '22023', message = 'The no-show grace period has not ended';
  end if;

  target_stage := case p_action
    when 'check_in' then 'checked_in'
    when 'complete' then 'completed'
    else 'no_show'
  end;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, p_action, array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  returning id into journal_id;

  update public.reservation_occurrences
  set lifecycle_stage = target_stage,
      attendance_marked_at = case when target_stage in ('completed', 'no_show') then now() else attendance_marked_at end,
      attendance_marked_by = case when target_stage in ('completed', 'no_show') then auth.uid() else attendance_marked_by end,
      attendance_reason = case when target_stage in ('completed', 'no_show') then nullif(trim(p_reason), '') else attendance_reason end
  where id = occurrence_row.id;

  if p_action = 'complete' then
    perform public.settle_loyalty_occurrence(occurrence_row.id, 'completed', null);
  end if;

  if p_action = 'check_in' then
    update public.reservation_requests
    set payment_status = case when payment_status = 'authorized' then 'captured' else payment_status end
    where id = p_request_id;
  elsif not exists (
    select 1 from public.reservation_occurrences
    where request_id = p_request_id
      and lifecycle_stage not in ('completed', 'no_show')
  ) then
    update public.reservation_requests
    set reservation_status = 'completed'
    where id = p_request_id;
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'consume', p_action);
  end if;

  event_id := public.reservation_event(
    p_request_id,
    replace(p_action, '_', ' '),
    p_reason,
    jsonb_build_object('occurrence_id', occurrence_row.id),
    occurrence_row.id,
    p_action <> 'check_in'
  );

  if p_action <> 'check_in' then
    perform public.notify_reservation_user(
      p_request_id,
      event_id,
      'reservation_' || p_action,
      initcap(replace(p_action, '_', ' ')),
      coalesce(nullif(trim(p_reason), ''), 'Your reservation attendance was updated.')
    );
  end if;

  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;

  return jsonb_build_object('request_id', p_request_id, 'action_id', null, 'undo_until', null);
end;
$$;

create or replace function public.correct_occurrence_attendance(
  p_occurrence_id uuid,
  p_target_stage text,
  p_reason text,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_row public.reservation_occurrences%rowtype;
  request_row public.reservation_requests%rowtype;
  reason_value text := nullif(trim(p_reason), '');
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_target_stage not in ('completed', 'no_show') then
    raise exception using errcode = '22023', message = 'Attendance can only be corrected to completed or no-show';
  end if;
  if reason_value is null or length(reason_value) < 3 then
    raise exception using errcode = '22023', message = 'A correction reason is required';
  end if;

  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id
  for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Occurrence not found';
  end if;
  if occurrence_row.lifecycle_stage not in ('completed', 'no_show') then
    raise exception using errcode = '22023', message = 'Only terminal attendance can be corrected';
  end if;
  if occurrence_row.lifecycle_stage = p_target_stage then
    raise exception using errcode = '22023', message = 'Choose a different attendance outcome';
  end if;

  select * into request_row
  from public.reservation_requests
  where id = occurrence_row.request_id
  for update;
  if not public.lock_reservation_admin_scope(request_row.id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    return jsonb_build_object('duplicate', true, 'request_id', request_row.id);
  end if;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  ) values (
    auth.uid(), p_idempotency_key, 'attendance_correction', array[request_row.id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  ) returning id into journal_id;

  update public.reservation_occurrences
  set lifecycle_stage = p_target_stage,
      attendance_marked_at = now(),
      attendance_marked_by = auth.uid(),
      attendance_reason = reason_value
  where id = occurrence_row.id;

  if occurrence_row.lifecycle_stage = 'completed' and p_target_stage = 'no_show' then
    perform public.reverse_loyalty_occurrence(occurrence_row.id, journal_id);
  elsif occurrence_row.lifecycle_stage = 'no_show' and p_target_stage = 'completed' then
    perform public.settle_loyalty_occurrence(occurrence_row.id, 'completed', journal_id);
  end if;

  perform public.reservation_event(
    request_row.id,
    'attendance corrected',
    reason_value,
    jsonb_build_object(
      'event_key', 'ATTENDANCE_CORRECTED',
      'occurrence_id', occurrence_row.id,
      'from', occurrence_row.lifecycle_stage,
      'to', p_target_stage
    ),
    occurrence_row.id,
    true
  );

  return jsonb_build_object('ok', true, 'request_id', request_row.id);
end;
$$;

create or replace function public.submit_reservation_feedback(
  p_reservation_id uuid,
  p_rating integer,
  p_comment text default '',
  p_cleanliness integer default null,
  p_condition integer default null,
  p_equipment integer default null
) returns public.reservation_feedback
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.reservation_feedback%rowtype;
  awarded_id uuid;
  award_points numeric;
  clean_comment text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Choose a rating from 1 to 5';
  end if;
  if p_cleanliness is not null and p_cleanliness not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Cleanliness rating must be between 1 and 5';
  end if;
  if p_condition is not null and p_condition not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Condition rating must be between 1 and 5';
  end if;
  if p_equipment is not null and p_equipment not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Equipment rating must be between 1 and 5';
  end if;
  clean_comment := trim(coalesce(p_comment, ''));
  if length(clean_comment) > 500 then
    raise exception using errcode = '22023', message = 'Keep your comment under 500 characters';
  end if;

  select * into request_row from public.reservation_requests
  where id = p_reservation_id for update;

  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Feedback is limited to the person who booked';
  end if;
  if request_row.reservation_status <> 'completed'
     or not exists (
       select 1 from public.reservation_occurrences
       where request_id = p_reservation_id and lifecycle_stage = 'completed'
     ) then
    raise exception using errcode = '22023', message = 'Feedback opens once the reservation is completed';
  end if;

  begin
    insert into public.reservation_feedback(
      reservation_id, facility_id, user_id, rating,
      cleanliness_rating, condition_rating, equipment_rating, comment
    ) values (
      p_reservation_id, request_row.facility_id, auth.uid(), p_rating,
      p_cleanliness, p_condition, p_equipment, clean_comment
    )
    returning * into result;
  exception when unique_violation then
    raise exception using errcode = '23505', message = 'You already left feedback for this reservation';
  end;

  if request_row.pricing_audience = 'guest'
     and public.loyalty_user_is_eligible(auth.uid()) then
    award_points := public.loyalty_points_for('feedback_submitted');
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description
    ) values (
      auth.uid(), award_points, 'feedback_submitted', 'feedback',
      result.id, 'Feedback for ' || request_row.facility_name
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
    returning id into awarded_id;

    if awarded_id is not null then
      insert into public.app_notifications(recipient_id, request_id, kind, title, body)
      values (
        auth.uid(), p_reservation_id, 'loyalty_earned',
        '+' || trim(to_char(award_points, 'FM999999990.0')) || ' points',
        'Thanks for rating ' || request_row.facility_name || '.'
      );
    end if;
  end if;

  if p_rating <= 2 then
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    select a.id, p_reservation_id, 'feedback_low_rating',
           p_rating || ' star rating for ' || request_row.facility_name,
           coalesce(nullif(clean_comment, ''), 'No comment left.')
    from public.profiles a
    where a.account_status = 'active'
      and (
        a.role = 'internal_admin'
        or (a.role = 'external_admin' and public.can_manage_facility(request_row.facility_id, a.id))
      )
    on conflict (recipient_id, request_id, kind) where kind = 'feedback_low_rating' do nothing;
  end if;

  perform public.reservation_event(
    p_reservation_id, 'left feedback', null,
    jsonb_build_object('rating', p_rating), null, false
  );

  return result;
end;
$$;

-- Only the changed portions of cancellation/reservation_action/expiration are
-- recreated here, preserving the current behavior while settling vouchers.
create or replace function public.cancel_reservation_action(
  p_request_id uuid,
  p_reason text default null,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
  event_id uuid;
  target_occurrence_id uuid;
  cancelled_count integer;
  remaining_future boolean;
  undoable boolean;
  reason_value text := coalesce(nullif(trim(p_reason), ''), 'Cancelled by requester');
  now_version integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> 'cancel' or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023',
        message = 'That cancellation key was already used for another action';
    end if;
    select not exists (
      select 1 from public.payment_transactions p
      where p.request_id = p_request_id
        and p.status in ('submitted', 'verified', 'refunded')
    ) into undoable;
    return jsonb_build_object(
      'duplicate', true,
      'action_id', case when undoable then existing_journal.id else null end,
      'undo_until', case when undoable then existing_journal.undo_until else null end
    );
  end if;

  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;
  if request_row.status in ('declined', 'cancelled', 'expired')
     or request_row.reservation_status in ('declined', 'cancelled', 'expired', 'completed') then
    raise exception using errcode = '22023', message = 'A terminal reservation cannot be cancelled';
  end if;

  perform 1
  from public.reservation_occurrences
  where request_id = p_request_id
  order by id
  for update;

  if p_payload ? 'occurrence_id' then
    begin
      target_occurrence_id := (p_payload->>'occurrence_id')::uuid;
    exception when invalid_text_representation then
      raise exception using errcode = '22023', message = 'Choose a valid reservation date';
    end;
  end if;

  if not exists (
    select 1
    from public.reservation_occurrences o
    where o.request_id = p_request_id
      and (target_occurrence_id is null or o.id = target_occurrence_id)
      and o.starts_at > now()
      and o.lifecycle_stage = 'booked'
      and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped')
  ) then
    raise exception using errcode = '22023',
      message = 'Only future reservations that have not started can be cancelled';
  end if;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, 'cancel', array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)),
    coalesce((select jsonb_agg(to_jsonb(o) order by o.starts_at)
      from public.reservation_occurrences o
      where o.request_id = p_request_id), '[]'::jsonb)
  returning id into journal_id;

  update public.reservation_occurrences o
  set booking_state = 'cancelled',
      exception_reason = reason_value,
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = reason_value
  where o.request_id = p_request_id
    and (target_occurrence_id is null or o.id = target_occurrence_id)
    and o.starts_at > now()
    and o.lifecycle_stage = 'booked'
    and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped');
  get diagnostics cancelled_count = row_count;
  if cancelled_count = 0 then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;

  select exists (
    select 1
    from public.reservation_occurrences o
    where o.request_id = p_request_id
      and o.starts_at > now()
      and o.lifecycle_stage in ('booked', 'checked_in')
      and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped')
  ) into remaining_future;

  update public.reservation_requests
  set status = case when remaining_future then status else 'cancelled' end,
      reservation_status = case when remaining_future then reservation_status else 'cancelled' end,
      decision_reason = case when remaining_future then decision_reason else reason_value end,
      terminal_at = case when remaining_future then terminal_at else now() end,
      terminal_reason_code = case when remaining_future then terminal_reason_code else null end,
      payment_status = case when not remaining_future and payment_status in ('quoted', 'authorized') then 'voided' else payment_status end,
      payment_due_at = case when remaining_future then payment_due_at else null end,
      balance_due_at = case when remaining_future then balance_due_at else null end,
      updated_at = now()
  where id = p_request_id;

  if not remaining_future then
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'release', reason_value);
  end if;

  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;

  event_id := public.reservation_event(
    p_request_id,
    'cancel',
    reason_value,
    jsonb_build_object('occurrence_id', target_occurrence_id, 'cancelled_occurrences', cancelled_count),
    target_occurrence_id,
    true
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_cancel',
    'Reservation cancelled',
    reason_value
  );

  select not exists (
    select 1 from public.payment_transactions p
    where p.request_id = p_request_id
      and p.status in ('submitted', 'verified', 'refunded')
  ) into undoable;

  return jsonb_build_object(
    'request_id', p_request_id,
    'action_id', case when undoable then journal_id else null end,
    'undo_until', case when undoable then now() + interval '8 seconds' else null end
  );
end;
$$;

create or replace function public.reservation_action(
  p_request_id uuid,
  p_action text,
  p_reason text default null,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  if p_action = 'cancel' then
    return public.cancel_reservation_action(
      p_request_id, p_reason, p_payload, p_expected_version, p_idempotency_key
    );
  end if;
  if p_action in ('check_in', 'complete', 'no_show') then
    if not (p_payload ? 'occurrence_id') then
      raise exception using errcode = '22023', message = 'Choose a reservation date';
    end if;
    return public.record_occurrence_attendance(
      p_request_id,
      (p_payload->>'occurrence_id')::uuid,
      p_action,
      p_reason,
      p_expected_version,
      p_idempotency_key
    );
  end if;
  if p_action in (
    'approve', 'approve_partial', 'approve_bump', 'decline', 'request_changes',
    'offer_alternative', 'reopen', 'expire'
  ) and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_action in ('accept_alternative', 'resubmit') and not (
    public.lock_reservation_admin_scope(p_request_id) or exists(
      select 1 from public.reservation_requests
      where id = p_request_id and requester_id = auth.uid()
    )
  ) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_action = 'reopen' then
    raise exception using errcode = '22023', message = 'Declined and terminal reservations cannot be reopened';
  end if;

  result := public.reservation_action_unscoped(
    p_request_id, p_action, p_reason, p_payload, p_expected_version, p_idempotency_key);

  if p_action in ('approve', 'approve_partial', 'accept_alternative') then
    perform public.apply_reservation_payment_gate(p_request_id);
  elsif p_action in ('request_changes', 'offer_alternative') then
    update public.reservation_requests set reservation_status = 'changes_requested' where id = p_request_id;
  elsif p_action = 'decline' then
    update public.reservation_requests
    set reservation_status = 'declined', terminal_at = now(), terminal_reason_code = null
    where id = p_request_id;
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'release', p_reason);
  elsif p_action = 'expire' then
    update public.reservation_requests
    set reservation_status = 'expired', terminal_at = now(), terminal_reason_code = 'stale_pending'
    where id = p_request_id;
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'release', 'Expired');
  end if;
  return result;
end;
$$;

create or replace function public.expire_due_reservations(
  p_dry_run boolean default false
)
returns table(request_id uuid, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate record;
  event_id uuid;
begin
  for candidate in
    select
      request.id,
      case
        when request.reservation_status = 'awaiting_payment'
          then 'Down payment deadline missed'
        else 'Remaining balance deadline missed'
      end as reason_value,
      case
        when request.reservation_status = 'awaiting_payment'
          then 'down_payment_deadline'
        else 'balance_payment_deadline'
      end as reason_code
    from public.reservation_requests as request
    where not request.legacy_financial_state
      and (
        (
          request.reservation_status = 'awaiting_payment'
          and request.payment_due_at < now()
          and not exists (
            select 1 from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'submitted'
          )
        )
        or (
          request.reservation_status = 'confirmed'
          and request.total_amount_centavos > 0
          and request.balance_due_at < now()
          and not exists (
            select 1 from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'submitted'
          )
          and (
            select coalesce(sum(payment.amount_centavos), 0)
            from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'verified'
          ) < request.total_amount_centavos
        )
      )
    order by request.id
    for update
  loop
    request_id := candidate.id;
    reason := candidate.reason_value;

    if not p_dry_run then
      update public.reservation_occurrences as occurrence
      set booking_state = 'expired',
          exception_reason = candidate.reason_value
      where occurrence.request_id = candidate.id
        and occurrence.booking_state in ('held', 'booked');

      update public.reservation_requests as request
      set reservation_status = 'expired',
          status = 'expired',
          decision_reason = candidate.reason_value,
          terminal_at = now(),
          terminal_reason_code = candidate.reason_code,
          decided_at = now()
      where request.id = candidate.id;

      perform public.settle_loyalty_discount_for_reservation(candidate.id, 'release', candidate.reason_value);

      event_id := public.reservation_event(
        candidate.id,
        'expired automatically',
        candidate.reason_value,
        jsonb_build_object('terminal_reason_code', candidate.reason_code),
        null,
        true
      );
      perform public.notify_reservation_user(
        candidate.id, event_id, 'reservation_expired', 'Reservation expired',
        candidate.reason_value || '. The facility and time slot are available again.'
      );
    end if;

    return next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- RLS and grants
-- ---------------------------------------------------------------------

alter table public.loyalty_discount_offers enable row level security;
alter table public.loyalty_discount_claims enable row level security;
alter table public.loyalty_discount_applications enable row level security;

revoke all on public.loyalty_discount_offers from public, anon, authenticated;
revoke all on public.loyalty_discount_claims from public, anon, authenticated;
revoke all on public.loyalty_discount_applications from public, anon, authenticated;

grant select on public.loyalty_discount_offers to authenticated;
grant select on public.loyalty_discount_claims to authenticated;
grant select on public.loyalty_discount_applications to authenticated;

drop policy if exists loyalty_discount_offers_read on public.loyalty_discount_offers;
create policy loyalty_discount_offers_read
on public.loyalty_discount_offers for select to authenticated
using (
  public.is_external_admin()
  or public.is_internal_admin()
  or (
    active
    and public.loyalty_user_is_eligible(auth.uid())
    and (now() at time zone 'Asia/Manila')::date between valid_from and valid_until
  )
);

drop policy if exists loyalty_discount_claims_read on public.loyalty_discount_claims;
create policy loyalty_discount_claims_read
on public.loyalty_discount_claims for select to authenticated
using (user_id = auth.uid() or public.is_internal_admin());

drop policy if exists loyalty_discount_applications_read on public.loyalty_discount_applications;
create policy loyalty_discount_applications_read
on public.loyalty_discount_applications for select to authenticated
using (
  public.is_internal_admin()
  or exists (
    select 1 from public.loyalty_discount_claims c
    where c.id = claim_id and c.user_id = auth.uid()
  )
);

revoke all on function public.save_loyalty_discount_offer(
  uuid, text, text, numeric, text, integer, numeric, uuid, date, date, boolean
) from public, anon;
revoke all on function public.set_loyalty_discount_offer_active(uuid, boolean) from public, anon;
revoke all on function public.loyalty_discount_offer_admin_list() from public, anon;
revoke all on function public.claim_loyalty_discount(uuid) from public, anon;
revoke all on function public.loyalty_balance(uuid) from public, anon;
revoke all on function public.loyalty_my_summary() from public, anon;
revoke all on function public.loyalty_admin_balances(text, integer) from public, anon;
revoke all on function public.submit_reservation_feedback(uuid, integer, text, integer, integer, integer) from public, anon;
revoke all on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) from public, anon;
revoke all on function public.correct_occurrence_attendance(uuid, text, text, uuid) from public, anon;
revoke all on function public.cancel_reservation_action(uuid, text, jsonb, integer, uuid) from public, anon;
revoke all on function public.reservation_action(uuid, text, text, jsonb, integer, uuid) from public, anon;
revoke all on function public.expire_due_reservations(boolean) from public, anon, authenticated;

grant execute on function public.save_loyalty_discount_offer(
  uuid, text, text, numeric, text, integer, numeric, uuid, date, date, boolean
) to authenticated;
grant execute on function public.set_loyalty_discount_offer_active(uuid, boolean) to authenticated;
grant execute on function public.loyalty_discount_offer_admin_list() to authenticated;
grant execute on function public.claim_loyalty_discount(uuid) to authenticated;
grant execute on function public.loyalty_balance(uuid) to authenticated;
grant execute on function public.loyalty_my_summary() to authenticated;
grant execute on function public.loyalty_admin_balances(text, integer) to authenticated;
grant execute on function public.submit_reservation_feedback(uuid, integer, text, integer, integer, integer) to authenticated;
grant execute on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) to authenticated;
grant execute on function public.correct_occurrence_attendance(uuid, text, text, uuid) to authenticated;
grant execute on function public.cancel_reservation_action(uuid, text, jsonb, integer, uuid) to authenticated;
grant execute on function public.reservation_action(uuid, text, text, jsonb, integer, uuid) to authenticated;
grant execute on function public.expire_due_reservations(boolean) to service_role;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'loyalty_discount_claims'
  ) then
    alter publication supabase_realtime add table public.loyalty_discount_claims;
  end if;
end $$;

notify pgrst, 'reload schema';
