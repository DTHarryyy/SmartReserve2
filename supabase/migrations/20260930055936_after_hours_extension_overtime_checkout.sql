-- Campus after-hours pricing, paid time extensions, overtime and checkout.
--
-- 1. Campus (internal-lane) reservations are free only until 17:00 Manila
--    time. Booked minutes after 17:00 are charged per started hour at the
--    facility's overtime rate, through the normal quote -> payment gate.
-- 2. Requesters can ask to extend a booked occurrence; an administrator
--    approves it, which moves ends_at (the no-overlap constraint still
--    guards the calendar) and records a charge.
-- 3. Checkout (requester or administrator) completes a checked-in occurrence
--    and bills any overtime past ends_at after a 15-minute grace.
--
-- Extra charges never touch the immutable price snapshot on
-- reservation_requests. They live in reservation_time_charges, and every
-- payment check compares against reservation_payable_total() instead of
-- total_amount_centavos. Extra-time payments use purpose = 'adjustment'.
--
-- Billable extra time:
--   external lane: every minute past the previous end
--   internal lane: only minutes after 17:00
--   overtime:      nothing within overtime_grace_minutes, then whole hours
--   extensions:    whole hours

-- ---------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------

alter table public.facilities
  add column if not exists overtime_hourly_rate_centavos integer not null default 0
    check (overtime_hourly_rate_centavos >= 0),
  add column if not exists overtime_grace_minutes integer not null default 15
    check (overtime_grace_minutes between 0 and 120);

-- Existing facilities start with their guest hourly rate so extensions and
-- overtime are billable immediately; administrators can change it later.
update public.facilities f
set overtime_hourly_rate_centavos = coalesce((
  select r.hourly_rate_centavos
  from public.facility_rates r
  where r.facility_id = f.id and r.audience = 'guest'
), 0)
where f.overtime_hourly_rate_centavos = 0;

alter table public.reservation_occurrences
  add column if not exists checked_out_at timestamptz,
  add column if not exists checked_out_by uuid references public.profiles(id) on delete set null,
  add column if not exists overtime_minutes integer
    check (overtime_minutes is null or overtime_minutes >= 0);

create table if not exists public.reservation_time_charges (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  occurrence_id uuid not null references public.reservation_occurrences(id) on delete cascade,
  kind text not null check (kind in ('extension', 'overtime')),
  status text not null check (status in ('requested', 'approved', 'declined', 'cancelled', 'waived')),
  requested_minutes integer check (requested_minutes is null or requested_minutes > 0),
  previous_ends_at timestamptz,
  new_ends_at timestamptz,
  actual_end_at timestamptz,
  raw_over_minutes integer check (raw_over_minutes is null or raw_over_minutes >= 0),
  billable_minutes integer not null default 0 check (billable_minutes >= 0),
  hourly_rate_centavos integer not null default 0 check (hourly_rate_centavos >= 0),
  amount_centavos integer not null default 0 check (amount_centavos >= 0),
  reason text,
  decision_reason text,
  requested_by uuid references public.profiles(id) on delete set null,
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  idempotency_key uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    kind <> 'extension'
    or (requested_minutes is not null and previous_ends_at is not null
        and new_ends_at is not null and new_ends_at > previous_ends_at)
  ),
  check (kind <> 'overtime' or actual_end_at is not null)
);

create index if not exists reservation_time_charges_request_idx
  on public.reservation_time_charges(request_id, status);
create unique index if not exists reservation_time_charges_one_pending_extension_idx
  on public.reservation_time_charges(occurrence_id)
  where kind = 'extension' and status = 'requested';
create unique index if not exists reservation_time_charges_one_overtime_idx
  on public.reservation_time_charges(occurrence_id)
  where kind = 'overtime';
create unique index if not exists reservation_time_charges_idempotency_idx
  on public.reservation_time_charges(requested_by, idempotency_key)
  where idempotency_key is not null;

drop trigger if exists reservation_time_charges_touch on public.reservation_time_charges;
create trigger reservation_time_charges_touch
before update on public.reservation_time_charges
for each row execute procedure public.touch_reservation_row();

-- Clients follow reservation_requests changes and re-read the embeds, so a
-- charge change touches its request (bumping the version) to reach every
-- open screen: pending extensions for admins, new balances for requesters.
create or replace function public.touch_request_for_time_charge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.reservation_requests
  set updated_at = now()
  where id = new.request_id;
  return new;
end;
$$;

revoke all on function public.touch_request_for_time_charge() from public, anon, authenticated;

drop trigger if exists reservation_time_charges_touch_request on public.reservation_time_charges;
create trigger reservation_time_charges_touch_request
after insert or update on public.reservation_time_charges
for each row execute procedure public.touch_request_for_time_charge();

alter table public.reservation_time_charges enable row level security;

drop policy if exists reservation_time_charges_read on public.reservation_time_charges;
create policy reservation_time_charges_read
on public.reservation_time_charges for select to authenticated
using (public.can_access_reservation(request_id));

revoke all on public.reservation_time_charges from anon, authenticated;
grant select on public.reservation_time_charges to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public'
         and tablename = 'reservation_time_charges'
     ) then
    alter publication supabase_realtime add table public.reservation_time_charges;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Pure helpers
-- ---------------------------------------------------------------------

create or replace function public.campus_free_hours_end()
returns time
language sql
immutable
as $$ select time '17:00' $$;

-- Minutes of [p_starts_at, p_ends_at) that fall after 17:00 Manila time on
-- the start's date. Reservations are same-day, so one cutoff is enough.
create or replace function public.after_hours_minutes(
  p_starts_at timestamptz,
  p_ends_at timestamptz
) returns integer
language sql
immutable
set search_path = public
as $$
  select greatest(
    0,
    ceil(extract(epoch from (
      p_ends_at - greatest(
        p_starts_at,
        (((p_starts_at at time zone 'Asia/Manila')::date
          + public.campus_free_hours_end()) at time zone 'Asia/Manila')
      )
    )) / 60)
  )::integer;
$$;

-- Billable minutes (always whole hours) for time added between p_old_end and
-- p_new_end. p_grace_minutes is forgiven entirely when the billable time
-- does not exceed it (overtime); extensions pass 0.
create or replace function public.extra_time_billable_minutes(
  p_admin_lane text,
  p_old_end timestamptz,
  p_new_end timestamptz,
  p_grace_minutes integer default 0
) returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  raw_minutes integer;
begin
  if p_old_end is null or p_new_end is null or p_new_end <= p_old_end then
    return 0;
  end if;
  raw_minutes := case
    when p_admin_lane = 'internal' then public.after_hours_minutes(p_old_end, p_new_end)
    else ceil(extract(epoch from (p_new_end - p_old_end)) / 60)::integer
  end;
  if raw_minutes <= greatest(coalesce(p_grace_minutes, 0), 0) then
    return 0;
  end if;
  return ceil(raw_minutes / 60.0)::integer * 60;
end;
$$;

create or replace function public.reservation_extra_charges_total(p_request_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(amount_centavos), 0)::integer
  from public.reservation_time_charges
  where request_id = p_request_id and status = 'approved';
$$;

create or replace function public.reservation_payable_total(p_request_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select r.total_amount_centavos + public.reservation_extra_charges_total(r.id)
  from public.reservation_requests r
  where r.id = p_request_id;
$$;

revoke all on function public.reservation_extra_charges_total(uuid) from public, anon;
revoke all on function public.reservation_payable_total(uuid) from public, anon;
grant execute on function public.campus_free_hours_end() to authenticated;
grant execute on function public.after_hours_minutes(timestamptz, timestamptz) to authenticated;
grant execute on function public.extra_time_billable_minutes(text, timestamptz, timestamptz, integer) to authenticated;
grant execute on function public.reservation_extra_charges_total(uuid) to authenticated;
grant execute on function public.reservation_payable_total(uuid) to authenticated;

-- Makes sure a request that starts owing money has somewhere to pay.
-- Campus requests that were free at approval never got a payment method.
create or replace function public.ensure_reservation_payment_method(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  method_id uuid;
begin
  select * into request_row from public.reservation_requests where id = p_request_id;
  if request_row.id is null or request_row.payment_method_id is not null then
    return;
  end if;
  select id into method_id
  from public.facility_payment_methods
  where facility_id = request_row.facility_id and enabled
  order by case method_type when 'gcash' then 0 else 1 end, updated_at desc
  limit 1;
  if method_id is not null then
    update public.reservation_requests
    set payment_method_id = method_id
    where id = p_request_id;
  end if;
end;
$$;

revoke all on function public.ensure_reservation_payment_method(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Quote: campus requesters pay only for time after 17:00
-- ---------------------------------------------------------------------

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
  after_hours_total integer := 0;
  after_hours_billable integer := 0;
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
  exemption_value := case
    when lane_value = 'internal' then 'internal_user'
    when audience_value = 'student' then 'verified_student'
    when audience_value = 'faculty' then 'verified_faculty'
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
  if lane_value = 'internal' then
    -- Campus use is free until 17:00; later hours use the overtime rate.
    rate_value := facility.overtime_hourly_rate_centavos;
  elsif exemption_value = 'none' then
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
    after_hours_total := after_hours_total
      + public.after_hours_minutes(p_starts_at[i], p_ends_at[i]);
    after_hours_billable := after_hours_billable
      + ceil(public.after_hours_minutes(p_starts_at[i], p_ends_at[i]) / 60.0)::integer * 60;
  end loop;
  if lane_value = 'internal' then
    facility_total := (after_hours_billable / 60) * rate_value;
    lines_value := jsonb_build_array(jsonb_build_object(
      'line_type','facility','source_id',facility.id,
      'label',case when after_hours_billable > 0
        then facility.name::text || ' - after-hours use (after 5:00 PM)'
        else facility.name::text end,
      'quantity',case when after_hours_billable > 0
        then after_hours_billable / 60 else round(total_minutes / 60, 2) end,
      'unit_amount_centavos',case when after_hours_billable > 0 then rate_value else 0 end,
      'line_total_centavos',facility_total
    ));
  else
    facility_total := round(total_minutes * rate_value / 60)::integer;
    lines_value := jsonb_build_array(jsonb_build_object(
      'line_type','facility','source_id',facility.id,'label',facility.name::text,
      'quantity',round(total_minutes / 60, 2),'unit_amount_centavos',rate_value,
      'line_total_centavos',facility_total
    ));
  end if;
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
    'campus_free_hours_end',
      case when lane_value = 'internal'
        then to_char(public.campus_free_hours_end(), 'HH24:MI') end,
    'after_hours_minutes',
      case when lane_value = 'internal' then after_hours_total else 0 end,
    'after_hours_billable_minutes',
      case when lane_value = 'internal' then after_hours_billable else 0 end,
    'after_hours_rate_centavos',
      case when lane_value = 'internal' then rate_value else 0 end,
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


-- ---------------------------------------------------------------------
-- 4. Submission: stop zeroing campus prices; the quote already applies
--    the after-hours rule.
-- ---------------------------------------------------------------------

create or replace function public.submit_reservation_v3(
  p_request_id uuid,p_facility_id uuid,p_purpose text,p_headcount integer,p_starts_at timestamptz[],p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],p_terms_version_ids uuid[] default '{}'::uuid[],p_pricing_fingerprint text default null,
  p_attachment_metadata jsonb default '[]'::jsonb,p_requested_amenities text[] default '{}'::text[],p_discount_claim_id uuid default null,
  p_external_company_organization text default null,p_external_complete_address text default null,
  p_external_contact_numbers text[] default null,p_external_admission_fee_centavos integer default null,
  p_item_quantities jsonb default '{}'::jsonb
) returns public.reservation_requests
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  result public.reservation_requests%rowtype;
  category text;
begin
  result := public.submit_reservation_v2(
    p_request_id,p_facility_id,p_purpose,p_headcount,p_starts_at,p_ends_at,
    p_amenity_ids,p_terms_version_ids,p_pricing_fingerprint,
    p_attachment_metadata,p_requested_amenities,p_discount_claim_id
  );
  if result.admin_lane = 'external' then
    if nullif(trim(p_external_company_organization), '') is null
       or nullif(trim(p_external_complete_address), '') is null
       or cardinality(coalesce(p_external_contact_numbers, '{}')) = 0
       or p_external_admission_fee_centavos is null
       or p_external_admission_fee_centavos < 0 then
      raise exception using errcode = '22023', message = 'Complete all external permit details';
    end if;
    category := 'external_renter';
  else
    select case
      when p.account_access_type = 'organization_representative' then 'organization_representative'
      when p.campus_claim in ('student', 'faculty', 'staff') then p.campus_claim
      else 'verified_internal_user'
    end into category
    from public.profiles p where p.id = result.requester_id;
    -- Campus pricing (free until 17:00, after-hours at the overtime rate)
    -- is already applied by get_reservation_quote, so it is kept as quoted.
  end if;
  update public.reservation_requests
  set requester_category = category,
      requester_unit = case when category = 'organization_representative' then coalesce((
        select ou.name
        from public.profiles p
        join public.organization_account_slots os on os.id = p.organization_slot_id
        join public.organizational_units ou on ou.id = os.unit_id
        where p.id = result.requester_id
      ), result.requester_unit) else result.requester_unit end,
      external_company_organization = case when result.admin_lane = 'external' then trim(p_external_company_organization) end,
      external_complete_address = case when result.admin_lane = 'external' then trim(p_external_complete_address) end,
      external_contact_numbers = case when result.admin_lane = 'external' then p_external_contact_numbers end,
      external_admission_fee_centavos = case when result.admin_lane = 'external' then p_external_admission_fee_centavos end
  where id = result.id returning * into result;

  perform public.populate_reservation_permit_items(result.id);
  update public.reservation_permit_items item
  set requested_quantity = (p_item_quantities ->> item.source_id::text)::integer
  where item.request_id = result.id
    and item.row_code = 'external:tables_chairs'
    and p_item_quantities ? item.source_id::text
    and (p_item_quantities ->> item.source_id::text) ~ '^[1-9][0-9]*$';
  if result.admin_lane = 'external' and exists (
    select 1 from public.reservation_permit_items
    where request_id = result.id
      and row_code = 'external:tables_chairs'
      and requested_quantity is null
  ) then
    raise exception using errcode = '22023', message = 'Enter the requested tables/chairs quantity';
  end if;
  if not (public.get_reservation_permit_configuration(result.id)->>'ready')::boolean then
    raise exception using errcode = '22023',
      message = 'This facility needs official permit mappings before it can accept reservations';
  end if;
  return result;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Payment summary and payments against the payable total
-- ---------------------------------------------------------------------

create or replace function public.reservation_payment_summary(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  verified_value integer;
  submitted_value integer;
  correction_value integer;
  extra_value integer;
  pending_extension_value integer;
  payable_value integer;
  status_value text;
begin
  select * into request_row from public.reservation_requests where id = p_request_id;
  if request_row.id is null or not public.can_access_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  select coalesce(sum(amount_centavos) filter(where status = 'verified' and purpose <> 'refund'), 0),
         coalesce(sum(amount_centavos) filter(where status = 'submitted'), 0),
         coalesce(sum(amount_centavos) filter(where status = 'needs_correction'), 0)
  into verified_value, submitted_value, correction_value
  from public.payment_transactions
  where request_id = p_request_id;
  select coalesce(sum(amount_centavos) filter(where status = 'approved'), 0),
         coalesce(sum(amount_centavos) filter(where status = 'requested'), 0)
  into extra_value, pending_extension_value
  from public.reservation_time_charges
  where request_id = p_request_id;
  payable_value := request_row.total_amount_centavos + extra_value;
  status_value := case
    when payable_value = 0 then 'not_required'
    when verified_value >= payable_value then 'fully_paid'
    when correction_value > 0 then 'needs_correction'
    when verified_value < request_row.total_amount_centavos
      and verified_value >= request_row.required_down_payment_centavos
      and request_row.required_down_payment_centavos > 0 then 'down_payment_verified'
    when submitted_value > 0 then 'submitted'
    when verified_value > 0 then 'partially_paid'
    else 'unpaid'
  end;
  return jsonb_build_object(
    'status', status_value,
    'total_amount_centavos', request_row.total_amount_centavos,
    'extra_charges_centavos', extra_value,
    'pending_extension_centavos', pending_extension_value,
    'payable_total_centavos', payable_value,
    'required_down_payment_centavos', request_row.required_down_payment_centavos,
    'verified_amount_centavos', verified_value,
    'submitted_amount_centavos', submitted_value,
    'correction_amount_centavos', correction_value,
    'outstanding_amount_centavos', greatest(0, payable_value - verified_value),
    'payment_due_at', request_row.payment_due_at,
    'balance_due_at', request_row.balance_due_at,
    'down_payment_percent', request_row.down_payment_percent,
    'payment_exemption', request_row.payment_exemption
  );
end;
$$;

-- submit_payment / correct_payment_submission: accept 'adjustment' payments
-- for extra time, accept them after the reservation is completed, and cap
-- every payment at the payable total (base + approved extra charges).

create or replace function public.submit_payment(
  p_transaction_id uuid,
  p_request_id uuid,
  p_purpose text,
  p_amount_centavos integer,
  p_reference_number text,
  p_proof_path text,
  p_idempotency_key uuid,
  p_payment_method_id uuid default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  request_row public.reservation_requests%rowtype;
  method_row public.facility_payment_methods%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed', 'completed') then
    raise exception using errcode = '22023', message = 'This reservation is not accepting payments';
  end if;
  if p_purpose not in ('down_payment', 'balance', 'adjustment') or p_amount_centavos <= 0 then
    raise exception using errcode = '22023', message = 'Provide a valid payment amount and purpose';
  end if;
  if request_row.reservation_status = 'completed'
     and public.reservation_payable_total(p_request_id) <= coalesce((
       select sum(amount_centavos) from public.payment_transactions
       where request_id = p_request_id and status in ('submitted', 'needs_correction', 'verified')
     ), 0) then
    raise exception using errcode = '22023', message = 'This reservation is not accepting payments';
  end if;
  if p_payment_method_id is not null then
    select * into method_row
    from public.facility_payment_methods
    where id = p_payment_method_id
      and facility_id = request_row.facility_id
      and enabled;
    if method_row.id is null then
      raise exception using errcode = '22023',
        message = 'Choose a payment method published for this facility';
    end if;
  else
    if request_row.payment_method_id is null then
      raise exception using errcode = '22023', message = 'No payment method is configured for this reservation';
    end if;
    select * into method_row
    from public.facility_payment_methods
    where id = request_row.payment_method_id;
  end if;
  perform public.assert_payment_reference(method_row.method_type, p_reference_number);
  if p_proof_path not like auth.uid()::text || '/' || p_request_id::text || '/%' then
    raise exception using errcode = '42501', message = 'Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = p_request_id
    and status in ('submitted', 'needs_correction', 'verified');
  if p_amount_centavos > public.reservation_payable_total(request_row.id) - committed_value then
    raise exception using errcode = '22023', message = 'Payment is greater than the outstanding balance';
  end if;
  if request_row.payment_method_id is null then
    update public.reservation_requests set payment_method_id = method_row.id where id = p_request_id;
  end if;
  insert into public.payment_transactions(
    id, request_id, payer_id, payment_method_id, purpose, amount_centavos,
    reference_number, proof_path, idempotency_key
  ) values (
    p_transaction_id, p_request_id, auth.uid(), method_row.id,
    p_purpose, p_amount_centavos, trim(p_reference_number), p_proof_path,
    p_idempotency_key
  )
  returning * into result;
  event_id := public.reservation_event(
    p_request_id,
    'submitted payment proof',
    null,
    jsonb_build_object(
      'payment_id', result.id,
      'purpose', result.purpose,
      'method_type', method_row.method_type,
      'amount_centavos', result.amount_centavos
    ),
    null,
    true
  );
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, p_request_id, event_id, 'payment_submitted',
    'Payment submitted for review',
    request_row.requester_name ||
    case method_row.method_type
      when 'walk_in' then ' submitted a cashier receipt for review.'
      else ' submitted GCash payment proof.'
    end
  from public.profiles p
  where p.account_status = 'active'
    and p.role = case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  on conflict do nothing;
  return result;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'That payment reference or submission was already used';
end;
$$;


create or replace function public.correct_payment_submission(
  p_payment_id uuid,
  p_amount_centavos integer,
  p_reference_number text,
  p_proof_path text,
  p_idempotency_key uuid,
  p_payment_method_id uuid default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  payment_row public.payment_transactions%rowtype;
  request_row public.reservation_requests%rowtype;
  method_row public.facility_payment_methods%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into result
  from public.payment_transactions
  where payer_id = auth.uid()
    and idempotency_key = p_idempotency_key;
  if result.id is not null then
    return result;
  end if;
  select * into payment_row from public.payment_transactions where id = p_payment_id for update;
  if payment_row.id is null then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;
  select * into request_row from public.reservation_requests where id = payment_row.request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() or payment_row.payer_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if payment_row.status <> 'needs_correction' then
    raise exception using errcode = '22023', message = 'This payment is not awaiting correction';
  end if;
  if payment_row.correction_due_at is null or payment_row.correction_due_at < now() then
    raise exception using errcode = '22023', message = 'The payment correction window has ended';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed', 'completed') then
    raise exception using errcode = '22023', message = 'This reservation is no longer accepting payment corrections';
  end if;
  if p_amount_centavos <= 0 then
    raise exception using errcode = '22023', message = 'Provide a valid payment amount';
  end if;
  select * into method_row
  from public.facility_payment_methods
  where id = coalesce(p_payment_method_id, payment_row.payment_method_id)
    and facility_id = request_row.facility_id
    and (enabled or id = payment_row.payment_method_id);
  if method_row.id is null then
    raise exception using errcode = '22023',
      message = 'Choose a payment method published for this facility';
  end if;
  perform public.assert_payment_reference(method_row.method_type, p_reference_number);
  if p_proof_path not like auth.uid()::text || '/' || request_row.id::text || '/%' then
    raise exception using errcode = '42501', message = 'Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = request_row.id
    and id <> payment_row.id
    and status in ('submitted', 'needs_correction', 'verified');
  if p_amount_centavos > public.reservation_payable_total(request_row.id) - committed_value then
    raise exception using errcode = '22023', message = 'Payment is greater than the outstanding balance';
  end if;
  update public.payment_transactions
  set amount_centavos = p_amount_centavos,
      payment_method_id = method_row.id,
      reference_number = trim(p_reference_number),
      proof_path = p_proof_path,
      status = 'submitted',
      verified_by = null,
      verified_at = null,
      rejection_reason = null,
      correction_due_at = null,
      correction_count = correction_count + 1,
      last_corrected_at = now(),
      idempotency_key = p_idempotency_key
  where id = p_payment_id
  returning * into result;
  event_id := public.reservation_event(
    request_row.id,
    'corrected payment proof',
    null,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'previous_amount_centavos', payment_row.amount_centavos,
      'previous_reference_number', payment_row.reference_number,
      'previous_proof_path', payment_row.proof_path,
      'method_type', method_row.method_type,
      'amount_centavos', result.amount_centavos
    ),
    null,
    true
  );
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, request_row.id, event_id, 'payment_corrected',
    'Corrected payment submitted for review',
    request_row.requester_name ||
    case method_row.method_type
      when 'walk_in' then ' corrected a cashier receipt.'
      else ' corrected GCash payment proof.'
    end
  from public.profiles p
  where p.account_status = 'active'
    and p.role = case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  on conflict do nothing;
  return result;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'That payment reference or submission was already used';
end;
$$;

revoke all on function public.submit_payment(uuid, uuid, text, integer, text, text, uuid, uuid)
  from public, anon;

-- Based on the live definition (it no longer issues permits here). Changes:
-- extra-time payments on completed reservations can be reviewed, a rejected
-- extra-time payment leaves a completed reservation completed, and the
-- notice no longer assumes GCash.
create or replace function public.decide_payment(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public
as $$
declare payment_row public.payment_transactions%rowtype; request_row public.reservation_requests%rowtype;
declare result public.payment_transactions%rowtype; verified_value integer; amount_due_now integer; event_id uuid;
declare correction_deadline timestamptz;
begin
  select * into payment_row from public.payment_transactions where id=p_payment_id for update;
  if payment_row.id is null then raise exception using errcode='P0002',message='Payment not found'; end if;
  select * into request_row from public.reservation_requests where id=payment_row.request_id for update;
  if not public.lock_reservation_admin_scope(request_row.id) then raise exception using errcode='42501',message='Payment review access denied'; end if;
  if request_row.reservation_status not in ('awaiting_payment','confirmed','completed') then raise exception using errcode='22023',message='This reservation is no longer accepting payment decisions'; end if;
  if payment_row.status<>'submitted' then raise exception using errcode='22023',message='This payment has already been reviewed'; end if;
  if p_decision='reject' then
    if length(trim(coalesce(p_reason,'')))<3 then raise exception using errcode='22023',message='A rejection reason is required'; end if;
    correction_deadline := now() + interval '24 hours';
    update public.payment_transactions set status='needs_correction',verified_by=auth.uid(),verified_at=now(),rejection_reason=trim(p_reason),correction_due_at=correction_deadline where id=p_payment_id returning * into result;
    update public.reservation_requests set reservation_status=case when reservation_status in ('confirmed','completed') then reservation_status else 'awaiting_payment' end,
      payment_due_at=case when reservation_status='awaiting_payment' then correction_deadline else payment_due_at end where id=request_row.id;
    event_id:=public.reservation_event(request_row.id,'payment needs correction',trim(p_reason),jsonb_build_object('payment_id',payment_row.id,'correction_due_at',correction_deadline,'status','needs_correction'),null,true);
  elsif p_decision='verify' then
    update public.payment_transactions set status='verified',verified_by=auth.uid(),verified_at=now(),rejection_reason=null,correction_due_at=null where id=p_payment_id returning * into result;
    select coalesce(sum(amount_centavos),0) into verified_value from public.payment_transactions where request_id=request_row.id and status='verified';
    amount_due_now:=case when request_row.balance_due_at is not null and request_row.balance_due_at<=now() then request_row.total_amount_centavos else request_row.required_down_payment_centavos end;
    if request_row.reservation_status='awaiting_payment' and verified_value>=amount_due_now then
      update public.reservation_occurrences set booking_state='booked' where request_id=request_row.id and booking_state='held';
      update public.reservation_requests set reservation_status='confirmed',payment_due_at=null where id=request_row.id;
    end if;
    event_id:=public.reservation_event(request_row.id,'verified payment',null,jsonb_build_object('payment_id',payment_row.id,'amount_centavos',payment_row.amount_centavos,'verified_total_centavos',verified_value),null,true);
  else raise exception using errcode='22023',message='Decision must be verify or reject'; end if;
  perform public.notify_reservation_user(request_row.id,event_id,
    case p_decision when 'verify' then 'payment_verify' else 'payment_needs_correction' end,
    case p_decision when 'verify' then 'Payment verified' else 'Payment needs correction' end,
    case p_decision when 'verify' then 'Your payment was verified.'
      else trim(p_reason) || ' Correct by ' || to_char(correction_deadline at time zone 'Asia/Manila', 'Mon DD, YYYY HH12:MI AM') || '.' end);
  return result;
exception when exclusion_violation then raise exception using errcode='23P01',message='The held schedule is no longer available';
end;
$$;


-- ---------------------------------------------------------------------
-- 6. Extension and checkout building blocks
-- ---------------------------------------------------------------------

create or replace function public.notify_reservation_lane_admins(
  p_request_id uuid,
  p_event_id uuid,
  p_kind text,
  p_title text,
  p_body text
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, r.id, p_event_id, p_kind, p_title, p_body
  from public.reservation_requests r
  join public.profiles p
    on p.account_status = 'active'
   and p.role = case r.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  where r.id = p_request_id
  on conflict do nothing;
$$;

revoke all on function public.notify_reservation_lane_admins(uuid, uuid, text, text, text)
  from public, anon, authenticated;

create or replace function public.format_peso(p_centavos integer)
returns text
language sql
immutable
as $$
  select 'PHP ' || trim(to_char(coalesce(p_centavos, 0)::numeric / 100, 'FM999,999,999,990.00'));
$$;

-- Validates moving an occurrence's end time later: same day, within closing
-- time, optionally within the facility maximum duration, and not into the
-- next booking (including both buffers, exactly like the exclusion
-- constraint that guards the final update).
create or replace function public.assert_occurrence_end_change(
  p_occurrence_id uuid,
  p_new_end timestamptz,
  p_enforce_max_duration boolean
) returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  occurrence_row public.reservation_occurrences%rowtype;
  facility public.facilities%rowtype;
  local_start timestamp;
  local_end timestamp;
begin
  select * into occurrence_row from public.reservation_occurrences where id = p_occurrence_id;
  select * into facility from public.facilities where id = occurrence_row.facility_id;
  if p_new_end <= occurrence_row.ends_at then
    raise exception using errcode = '22023',
      message = 'The new end time must be later than the current end time';
  end if;
  local_start := occurrence_row.starts_at at time zone 'Asia/Manila';
  local_end := p_new_end at time zone 'Asia/Manila';
  if local_end::date <> local_start::date or local_end::time > facility.close_time then
    raise exception using errcode = '22023',
      message = 'Extensions must end by the facility closing time (' ||
        to_char(facility.close_time, 'HH12:MI AM') || ')';
  end if;
  if p_enforce_max_duration
     and extract(epoch from (p_new_end - occurrence_row.starts_at)) / 60
       > facility.max_duration_minutes then
    raise exception using errcode = '22023',
      message = 'The extension would exceed the facility maximum duration';
  end if;
  if exists (
    select 1
    from public.reservation_occurrences other
    where other.facility_id = occurrence_row.facility_id
      and other.id <> occurrence_row.id
      and other.booking_state in ('held', 'booked')
      and other.blocked_window && tstzrange(
        occurrence_row.starts_at - occurrence_row.buffer_minutes * interval '1 minute',
        p_new_end + occurrence_row.buffer_minutes * interval '1 minute',
        '[)'
      )
  ) then
    raise exception using errcode = '23P01',
      message = 'The facility is booked right after this slot';
  end if;
end;
$$;

revoke all on function public.assert_occurrence_end_change(uuid, timestamptz, boolean)
  from public, anon, authenticated;

-- Moves ends_at for a requested extension and prices it. Callers own the
-- authorization checks.
create or replace function public.apply_time_extension(
  p_charge_id uuid,
  p_enforce_max_duration boolean,
  p_reason text
) returns public.reservation_time_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  charge_row public.reservation_time_charges%rowtype;
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  facility public.facilities%rowtype;
  billable integer;
  result public.reservation_time_charges%rowtype;
begin
  select * into charge_row from public.reservation_time_charges where id = p_charge_id for update;
  select * into request_row from public.reservation_requests where id = charge_row.request_id for update;
  select * into occurrence_row from public.reservation_occurrences where id = charge_row.occurrence_id for update;
  select * into facility from public.facilities where id = occurrence_row.facility_id;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed reservation can be extended';
  end if;
  if occurrence_row.booking_state <> 'booked'
     or occurrence_row.lifecycle_stage not in ('booked', 'checked_in') then
    raise exception using errcode = '22023', message = 'This booking can no longer be extended';
  end if;
  if occurrence_row.ends_at <> charge_row.previous_ends_at then
    raise exception using errcode = '40001',
      message = 'The booking time changed. Ask for a new extension';
  end if;
  perform public.assert_occurrence_end_change(
    occurrence_row.id, charge_row.new_ends_at, p_enforce_max_duration
  );
  update public.reservation_occurrences
  set ends_at = charge_row.new_ends_at
  where id = occurrence_row.id;
  billable := public.extra_time_billable_minutes(
    request_row.admin_lane, charge_row.previous_ends_at, charge_row.new_ends_at, 0
  );
  update public.reservation_time_charges
  set status = 'approved',
      billable_minutes = billable,
      hourly_rate_centavos = facility.overtime_hourly_rate_centavos,
      amount_centavos = (billable / 60) * facility.overtime_hourly_rate_centavos,
      decided_by = auth.uid(),
      decided_at = now(),
      decision_reason = nullif(trim(p_reason), '')
  where id = charge_row.id
  returning * into result;
  if result.amount_centavos > 0 then
    perform public.ensure_reservation_payment_method(request_row.id);
  end if;
  return result;
exception when exclusion_violation then
  raise exception using errcode = '23P01', message = 'The facility is booked right after this slot';
end;
$$;

revoke all on function public.apply_time_extension(uuid, boolean, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Requester: ask for (or withdraw) an extension
-- ---------------------------------------------------------------------

create or replace function public.request_time_extension(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_hours integer,
  p_reason text default null,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns public.reservation_time_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  facility public.facilities%rowtype;
  result public.reservation_time_charges%rowtype;
  new_end timestamptz;
  billable integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into result
  from public.reservation_time_charges
  where requested_by = auth.uid() and idempotency_key = p_idempotency_key;
  if result.id is not null then
    return result;
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed reservation can be extended';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;
  if p_hours is null or p_hours not between 1 and 12 then
    raise exception using errcode = '22023', message = 'Choose between 1 and 12 extra hours';
  end if;
  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null or occurrence_row.booking_state <> 'booked'
     or occurrence_row.lifecycle_stage not in ('booked', 'checked_in') then
    raise exception using errcode = '22023', message = 'This booking can no longer be extended';
  end if;
  if now() >= occurrence_row.ends_at then
    raise exception using errcode = '22023',
      message = 'This booking has already ended. Overtime is billed at checkout';
  end if;
  if exists (
    select 1 from public.reservation_time_charges
    where occurrence_id = occurrence_row.id and kind = 'extension' and status = 'requested'
  ) then
    raise exception using errcode = '22023', message = 'An extension request is already waiting for review';
  end if;
  select * into facility from public.facilities where id = occurrence_row.facility_id;
  new_end := occurrence_row.ends_at + make_interval(hours => p_hours);
  perform public.assert_occurrence_end_change(occurrence_row.id, new_end, true);
  billable := public.extra_time_billable_minutes(
    request_row.admin_lane, occurrence_row.ends_at, new_end, 0
  );
  insert into public.reservation_time_charges(
    request_id, occurrence_id, kind, status, requested_minutes, previous_ends_at,
    new_ends_at, billable_minutes, hourly_rate_centavos, amount_centavos, reason,
    requested_by, idempotency_key
  ) values (
    request_row.id, occurrence_row.id, 'extension', 'requested', p_hours * 60,
    occurrence_row.ends_at, new_end, billable, facility.overtime_hourly_rate_centavos,
    (billable / 60) * facility.overtime_hourly_rate_centavos, nullif(trim(p_reason), ''),
    auth.uid(), p_idempotency_key
  ) returning * into result;
  event_id := public.reservation_event(
    request_row.id,
    'requested time extension',
    nullif(trim(p_reason), ''),
    jsonb_build_object(
      'charge_id', result.id,
      'occurrence_id', occurrence_row.id,
      'previous_ends_at', result.previous_ends_at,
      'new_ends_at', result.new_ends_at,
      'amount_centavos', result.amount_centavos
    ),
    occurrence_row.id,
    false
  );
  perform public.notify_reservation_lane_admins(
    request_row.id,
    event_id,
    'reservation_extension_requested',
    'Extension requested',
    request_row.requester_name || ' asked to extend ' || request_row.facility_name ||
      ' until ' || to_char(new_end at time zone 'Asia/Manila', 'HH12:MI AM') ||
      case when result.amount_centavos > 0
        then ' (' || public.format_peso(result.amount_centavos) || ').'
        else ' (no charge).' end
  );
  return result;
end;
$$;

create or replace function public.cancel_time_extension(p_charge_id uuid)
returns public.reservation_time_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.reservation_time_charges%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  update public.reservation_time_charges c
  set status = 'cancelled', decided_at = now(), decided_by = auth.uid()
  where c.id = p_charge_id
    and c.kind = 'extension'
    and c.status = 'requested'
    and exists (
      select 1 from public.reservation_requests r
      where r.id = c.request_id and r.requester_id = auth.uid()
    )
  returning * into result;
  if result.id is null then
    raise exception using errcode = '22023', message = 'This extension request cannot be withdrawn';
  end if;
  perform public.reservation_event(
    result.request_id, 'withdrew time extension', null,
    jsonb_build_object('charge_id', result.id), result.occurrence_id, false
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Administrator: decide, extend on the spot, waive
-- ---------------------------------------------------------------------

create or replace function public.decide_time_extension(
  p_charge_id uuid,
  p_decision text,
  p_reason text default null
) returns public.reservation_time_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  charge_row public.reservation_time_charges%rowtype;
  result public.reservation_time_charges%rowtype;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into charge_row from public.reservation_time_charges where id = p_charge_id;
  if charge_row.id is null then
    raise exception using errcode = 'P0002', message = 'Extension request not found';
  end if;
  if not public.lock_reservation_admin_scope(charge_row.request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  perform 1 from public.reservation_requests where id = charge_row.request_id for update;
  select * into charge_row from public.reservation_time_charges where id = p_charge_id for update;
  if charge_row.kind <> 'extension' or charge_row.status <> 'requested' then
    raise exception using errcode = '22023', message = 'This extension request was already decided';
  end if;
  if p_decision = 'approve' then
    result := public.apply_time_extension(charge_row.id, true, p_reason);
    event_id := public.reservation_event(
      result.request_id, 'approved time extension', nullif(trim(p_reason), ''),
      jsonb_build_object(
        'charge_id', result.id,
        'new_ends_at', result.new_ends_at,
        'amount_centavos', result.amount_centavos
      ),
      result.occurrence_id, true
    );
    perform public.notify_reservation_user(
      result.request_id, event_id, 'reservation_extension_decided',
      'Extension approved',
      'Your booking now ends at ' ||
        to_char(result.new_ends_at at time zone 'Asia/Manila', 'HH12:MI AM') || '. ' ||
        case when result.amount_centavos > 0
          then public.format_peso(result.amount_centavos) || ' was added to your balance.'
          else 'No extra charge applies.' end
    );
  elsif p_decision = 'decline' then
    update public.reservation_time_charges
    set status = 'declined',
        decided_by = auth.uid(),
        decided_at = now(),
        decision_reason = nullif(trim(p_reason), '')
    where id = charge_row.id
    returning * into result;
    event_id := public.reservation_event(
      result.request_id, 'declined time extension', nullif(trim(p_reason), ''),
      jsonb_build_object('charge_id', result.id), result.occurrence_id, false
    );
    perform public.notify_reservation_user(
      result.request_id, event_id, 'reservation_extension_decided',
      'Extension declined',
      coalesce(nullif(trim(p_reason), ''), 'Your extension request was declined.')
    );
  else
    raise exception using errcode = '22023', message = 'Decision must be approve or decline';
  end if;
  return result;
end;
$$;

create or replace function public.admin_extend_occurrence(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_hours integer,
  p_reason text default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns public.reservation_time_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  result public.reservation_time_charges%rowtype;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  select * into result
  from public.reservation_time_charges
  where requested_by = auth.uid() and idempotency_key = p_idempotency_key;
  if result.id is not null then
    return result;
  end if;
  if p_hours is null or p_hours not between 1 and 12 then
    raise exception using errcode = '22023', message = 'Choose between 1 and 12 extra hours';
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Booking not found';
  end if;
  -- A pending requester extension is superseded by the on-site decision.
  update public.reservation_time_charges
  set status = 'cancelled', decided_by = auth.uid(), decided_at = now(),
      decision_reason = 'Superseded by an administrator extension'
  where occurrence_id = occurrence_row.id and kind = 'extension' and status = 'requested';
  insert into public.reservation_time_charges(
    request_id, occurrence_id, kind, status, requested_minutes, previous_ends_at,
    new_ends_at, reason, requested_by, idempotency_key
  ) values (
    request_row.id, occurrence_row.id, 'extension', 'requested', p_hours * 60,
    occurrence_row.ends_at, occurrence_row.ends_at + make_interval(hours => p_hours),
    nullif(trim(p_reason), ''), auth.uid(), p_idempotency_key
  ) returning * into result;
  -- Administrators may exceed the maximum duration, never the closing time
  -- or the next booking.
  result := public.apply_time_extension(result.id, false, p_reason);
  event_id := public.reservation_event(
    result.request_id, 'extended booking', nullif(trim(p_reason), ''),
    jsonb_build_object(
      'charge_id', result.id,
      'new_ends_at', result.new_ends_at,
      'amount_centavos', result.amount_centavos
    ),
    result.occurrence_id, true
  );
  perform public.notify_reservation_user(
    result.request_id, event_id, 'reservation_extension_decided',
    'Booking extended',
    'Your booking now ends at ' ||
      to_char(result.new_ends_at at time zone 'Asia/Manila', 'HH12:MI AM') || '. ' ||
      case when result.amount_centavos > 0
        then public.format_peso(result.amount_centavos) || ' was added to your balance.'
        else 'No extra charge applies.' end
  );
  return result;
end;
$$;

create or replace function public.waive_time_charge(
  p_charge_id uuid,
  p_reason text
) returns public.reservation_time_charges
language plpgsql
security definer
set search_path = public
as $$
declare
  charge_row public.reservation_time_charges%rowtype;
  result public.reservation_time_charges%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into charge_row from public.reservation_time_charges where id = p_charge_id;
  if charge_row.id is null then
    raise exception using errcode = 'P0002', message = 'Charge not found';
  end if;
  if not public.lock_reservation_admin_scope(charge_row.request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception using errcode = '22023', message = 'A reason is required to waive a charge';
  end if;
  perform 1 from public.reservation_requests where id = charge_row.request_id for update;
  select * into charge_row from public.reservation_time_charges where id = p_charge_id for update;
  if charge_row.status <> 'approved' or charge_row.amount_centavos = 0 then
    raise exception using errcode = '22023', message = 'Only an unpaid extra charge can be waived';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = charge_row.request_id
    and status in ('submitted', 'needs_correction', 'verified');
  if public.reservation_payable_total(charge_row.request_id) - charge_row.amount_centavos
       < committed_value then
    raise exception using errcode = '22023',
      message = 'This charge is already paid or has a payment under review';
  end if;
  update public.reservation_time_charges
  set status = 'waived', decided_by = auth.uid(), decided_at = now(),
      decision_reason = trim(p_reason)
  where id = charge_row.id
  returning * into result;
  event_id := public.reservation_event(
    result.request_id, 'waived extra charge', trim(p_reason),
    jsonb_build_object('charge_id', result.id, 'kind', result.kind,
      'amount_centavos', result.amount_centavos),
    result.occurrence_id, true
  );
  perform public.notify_reservation_user(
    result.request_id, event_id, 'reservation_charge_waived',
    'Extra charge waived',
    public.format_peso(result.amount_centavos) || ' ' || result.kind ||
      ' charge was waived. ' || trim(p_reason)
  );
  return result;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Checkout (requester or administrator) with overtime billing
-- ---------------------------------------------------------------------

create or replace function public.enforce_occurrence_completion_after_end()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- A recorded checkout may complete early (the requester left early).
  if old.lifecycle_stage = 'checked_in'
     and new.lifecycle_stage = 'completed'
     and new.checked_out_at is null
     and now() < new.ends_at then
    raise exception using
      errcode = '22023',
      message = 'Completion becomes available after the reservation end time';
  end if;
  return new;
end;
$$;

create or replace function public.check_out_occurrence(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_checked_out_at timestamptz default null,
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
  facility public.facilities%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  charge_row public.reservation_time_charges%rowtype;
  is_admin boolean;
  checkout_at timestamptz;
  raw_over integer;
  billable integer;
  amount integer;
  journal_id uuid;
  event_id uuid;
  now_version integer;
  verified_value integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  is_admin := public.lock_reservation_admin_scope(p_request_id);
  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> 'check_out' or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023', message = 'That checkout key was already used for another action';
    end if;
    return jsonb_build_object('duplicate', true, 'request_id', p_request_id,
      'action_id', null, 'undo_until', null);
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if not is_admin and request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed reservation can be checked out';
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
  if occurrence_row.lifecycle_stage <> 'checked_in' then
    raise exception using errcode = '22023', message = 'Check in before checking out';
  end if;
  if p_checked_out_at is not null and not is_admin then
    raise exception using errcode = '42501',
      message = 'Only an administrator can record an earlier checkout time';
  end if;
  checkout_at := coalesce(p_checked_out_at, now());
  if checkout_at > now() + interval '1 minute' then
    raise exception using errcode = '22023', message = 'Checkout time cannot be in the future';
  end if;
  if checkout_at < coalesce(occurrence_row.checked_in_at, occurrence_row.starts_at) then
    raise exception using errcode = '22023', message = 'Checkout time cannot be before check-in';
  end if;
  select * into facility from public.facilities where id = occurrence_row.facility_id;
  raw_over := greatest(
    0, ceil(extract(epoch from (checkout_at - occurrence_row.ends_at)) / 60)
  )::integer;
  billable := public.extra_time_billable_minutes(
    request_row.admin_lane, occurrence_row.ends_at, checkout_at,
    facility.overtime_grace_minutes
  );
  amount := (billable / 60) * facility.overtime_hourly_rate_centavos;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  ) values (
    auth.uid(), p_idempotency_key, 'check_out', array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  ) returning id into journal_id;

  update public.reservation_occurrences
  set lifecycle_stage = 'completed',
      checked_out_at = checkout_at,
      checked_out_by = auth.uid(),
      overtime_minutes = raw_over,
      attendance_marked_at = now(),
      attendance_marked_by = auth.uid(),
      attendance_reason = nullif(trim(p_reason), '')
  where id = occurrence_row.id;
  perform public.settle_loyalty_occurrence(occurrence_row.id, 'completed', null);

  if amount > 0 then
    insert into public.reservation_time_charges(
      request_id, occurrence_id, kind, status, actual_end_at, raw_over_minutes,
      billable_minutes, hourly_rate_centavos, amount_centavos, requested_by,
      decided_by, decided_at
    ) values (
      request_row.id, occurrence_row.id, 'overtime', 'approved', checkout_at, raw_over,
      billable, facility.overtime_hourly_rate_centavos, amount, auth.uid(),
      auth.uid(), now()
    ) returning * into charge_row;
    perform public.ensure_reservation_payment_method(request_row.id);
  end if;

  if not exists (
    select 1 from public.reservation_occurrences
    where request_id = p_request_id
      and lifecycle_stage not in ('completed', 'no_show')
  ) then
    update public.reservation_requests
    set reservation_status = 'completed'
    where id = p_request_id;
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'consume', 'complete');
  end if;

  event_id := public.reservation_event(
    p_request_id,
    'checked out',
    nullif(trim(p_reason), ''),
    jsonb_build_object(
      'occurrence_id', occurrence_row.id,
      'checked_out_at', checkout_at,
      'overtime_minutes', raw_over,
      'billable_minutes', billable,
      'amount_centavos', amount,
      'charge_id', charge_row.id,
      'actor', case when is_admin then 'administrator' else 'requester' end
    ),
    occurrence_row.id,
    true
  );
  if amount > 0 then
    perform public.notify_reservation_user(
      p_request_id, event_id, 'reservation_overtime_due',
      'Overtime charge due',
      format('You checked out %s minute%s after your booking ended. Overtime due: %s. Pay it from your reservation.',
        raw_over, case when raw_over = 1 then '' else 's' end, public.format_peso(amount))
    );
  else
    perform public.notify_reservation_user(
      p_request_id, event_id, 'reservation_complete',
      'Checked out',
      'Your checkout was recorded. Thank you for using ' || request_row.facility_name || '.'
    );
  end if;
  if not is_admin then
    perform public.notify_reservation_lane_admins(
      p_request_id, event_id, 'reservation_checked_out',
      'Requester checked out',
      request_row.requester_name || ' checked out of ' || request_row.facility_name ||
        case when amount > 0
          then ' with ' || public.format_peso(amount) || ' overtime due.'
          else '.' end
    );
  end if;

  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;
  select coalesce(sum(amount_centavos), 0) into verified_value
  from public.payment_transactions
  where request_id = p_request_id and status = 'verified' and purpose <> 'refund';
  return jsonb_build_object(
    'request_id', p_request_id,
    'occurrence_id', occurrence_row.id,
    'checked_out_at', checkout_at,
    'overtime_minutes', raw_over,
    'billable_minutes', billable,
    'amount_centavos', amount,
    'charge_id', charge_row.id,
    'outstanding_centavos',
      greatest(0, public.reservation_payable_total(p_request_id) - verified_value),
    'action_id', null,
    'undo_until', null
  );
end;
$$;

-- "Mark completed" now routes through checkout.
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
  if p_action not in ('complete', 'no_show') then
    raise exception using errcode = '22023', message = 'Administrator attendance can only complete or mark no-show. Requesters use self check-in.';
  end if;
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  -- "Mark completed" is an administrator checkout: it records the checkout
  -- time and bills any overtime past the booked end.
  if p_action = 'complete' then
    return public.check_out_occurrence(
      p_request_id, p_occurrence_id, null, p_reason, p_expected_version, p_idempotency_key
    );
  end if;
  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> p_action or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023', message = 'That attendance key was already used for another action';
    end if;
    return jsonb_build_object('duplicate', true, 'action_id', null, 'undo_until', null);
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
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
  if p_action = 'complete' and occurrence_row.lifecycle_stage <> 'checked_in' then
    raise exception using errcode = '22023', message = 'Check in before completing this booking';
  end if;
  if p_action = 'no_show' and now() < occurrence_row.starts_at + interval '30 minutes' then
    raise exception using errcode = '22023', message = 'The no-show grace period has not ended';
  end if;
  target_stage := case p_action when 'complete' then 'completed' else 'no_show' end;
  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, p_action, array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  returning id into journal_id;
  update public.reservation_occurrences
  set lifecycle_stage = target_stage,
      attendance_marked_at = now(),
      attendance_marked_by = auth.uid(),
      attendance_reason = nullif(trim(p_reason), '')
  where id = occurrence_row.id;
  if p_action = 'complete' then
    perform public.settle_loyalty_occurrence(occurrence_row.id, 'completed', null);
  end if;
  if not exists (
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
    true
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_' || p_action,
    initcap(replace(p_action, '_', ' ')),
    coalesce(nullif(trim(p_reason), ''), 'Your reservation attendance was updated.')
  );
  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;
  return jsonb_build_object('request_id', p_request_id, 'action_id', null, 'undo_until', null);
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------

revoke all on function public.request_time_extension(uuid, uuid, integer, text, integer, uuid) from public, anon;
revoke all on function public.cancel_time_extension(uuid) from public, anon;
revoke all on function public.decide_time_extension(uuid, text, text) from public, anon;
revoke all on function public.admin_extend_occurrence(uuid, uuid, integer, text, uuid) from public, anon;
revoke all on function public.waive_time_charge(uuid, text) from public, anon;
revoke all on function public.check_out_occurrence(uuid, uuid, timestamptz, text, integer, uuid) from public, anon;
grant execute on function public.request_time_extension(uuid, uuid, integer, text, integer, uuid) to authenticated;
grant execute on function public.cancel_time_extension(uuid) to authenticated;
grant execute on function public.decide_time_extension(uuid, text, text) to authenticated;
grant execute on function public.admin_extend_occurrence(uuid, uuid, integer, text, uuid) to authenticated;
grant execute on function public.waive_time_charge(uuid, text) to authenticated;
grant execute on function public.check_out_occurrence(uuid, uuid, timestamptz, text, integer, uuid) to authenticated;
grant execute on function public.format_peso(integer) to authenticated;

notify pgrst, 'reload schema';
