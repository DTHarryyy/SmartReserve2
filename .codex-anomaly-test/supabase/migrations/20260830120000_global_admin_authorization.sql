-- Replace facility-specific administrator assignments with global lane
-- administration. Any active internal_admin can manage every facility and
-- act on every internal-lane reservation; any active external_admin can
-- manage every facility and act on every external-lane reservation.
-- Facility availability continues to depend only on facility status,
-- public-listing flag, and classification, plus whether the requester's
-- lane currently has at least one active administrator
-- (has_active_admin_in_lane, introduced by
-- 20260830110000_global_lane_reservation_routing.sql).
--
-- facility_admin_assignments is archived, then left in place read-only and
-- unused. It is not modified further here: the legacy RPCs
-- (facility_assignment_directory / set_facility_admin_assignment /
-- remove_facility_admin_assignment) only have their execute grants revoked
-- so PostgREST can no longer reach them, but their bodies -- and the
-- is_facility_owner/has_facility_admin_lane predicates they still call --
-- are left untouched. Dropping the table, those RPCs, and those predicates
-- is a separately reviewed cleanup migration after a 30-day production
-- validation window.

-- ---------------------------------------------------------------------
-- 2.1 Archive and disable legacy assignments
-- ---------------------------------------------------------------------

create table if not exists public.facility_admin_assignment_archive (
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null,
  admin_id uuid not null,
  assignment_role text not null,
  assigned_by uuid,
  created_at timestamptz not null,
  archived_at timestamptz not null default now(),
  archived_by uuid,
  archive_batch uuid not null,
  unique (facility_id, admin_id, archive_batch)
);

alter table public.facility_admin_assignment_archive enable row level security;
revoke all on public.facility_admin_assignment_archive from public, anon, authenticated;

do $$
declare
  batch_id uuid := gen_random_uuid();
begin
  insert into public.facility_admin_assignment_archive(
    facility_id, admin_id, assignment_role, assigned_by, created_at,
    archived_by, archive_batch
  )
  select facility_id, admin_id, assignment_role, assigned_by, created_at,
    auth.uid(), batch_id
  from public.facility_admin_assignments;
end;
$$;

-- Newly created facilities no longer get a creator assignment.
drop trigger if exists facilities_assign_creator on public.facilities;

-- Nobody can read assignment rows through PostgREST any more; the grant
-- (select to authenticated, from 20260822100000) stays in place but RLS now
-- has no permissive policy to satisfy, so every read returns zero rows.
drop policy if exists facility_assignments_read on public.facility_admin_assignments;

-- Legacy assignment RPCs stop being reachable from the client. Bodies stay
-- (they still call is_facility_owner) until the dedicated cleanup migration.
revoke all on function public.facility_assignment_directory(uuid) from authenticated;
revoke all on function public.set_facility_admin_assignment(uuid, uuid, text) from authenticated;
revoke all on function public.remove_facility_admin_assignment(uuid, uuid) from authenticated;

-- ---------------------------------------------------------------------
-- 2.2 Canonical authorization predicates
-- ---------------------------------------------------------------------

create or replace function public.can_manage_facility(
  p_facility_id uuid,
  p_admin_id uuid default auth.uid()
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.facilities f where f.id = p_facility_id
  ) and exists (
    select 1 from public.profiles p
    where p.id = p_admin_id
      and p.account_status = 'active'
      and p.role in ('internal_admin', 'external_admin')
  );
$$;

create or replace function public.can_manage_reservation(
  p_request_id uuid,
  p_admin_id uuid default auth.uid()
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.reservation_requests r
    where r.id = p_request_id
      and public.admin_lane(p_admin_id) = r.admin_lane
  );
$$;

-- Used by every write RPC (approve/decline/attendance/cancel/payment
-- decisions/undo) to both gate the action and lock the caller's profile row
-- for the duration of the transaction. No longer joins
-- facility_admin_assignments: eligibility is purely "active admin whose
-- lane matches this reservation's snapshotted lane".
create or replace function public.lock_reservation_admin_scope(p_request_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform 1
  from public.reservation_requests r
  join public.profiles p on p.id = auth.uid()
  where r.id = p_request_id
    and p.account_status = 'active'
    and p.role in ('internal_admin', 'external_admin')
    and public.admin_lane(p.id) = r.admin_lane
  for share of p;
  return found;
end;
$$;

-- ---------------------------------------------------------------------
-- 2.3 Access and availability RPC
-- ---------------------------------------------------------------------

-- The out-parameter row type is changing (assignment_role dropped,
-- booking_unavailability_code added), which create-or-replace cannot do in
-- place.
drop function if exists public.my_facility_access();

create function public.my_facility_access()
returns table (
  facility_id uuid,
  can_manage boolean,
  supports_internal boolean,
  supports_external boolean,
  bookable boolean,
  booking_unavailability_code text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    f.id,
    public.can_manage_facility(f.id),
    f.facility_classification in ('internal', 'shared'),
    f.facility_classification in ('external', 'shared'),
    case
      when public.admin_lane() is not null then false
      when f.archived_at is not null or not f.public_listing or f.status <> 'active' then false
      when f.facility_classification not in ('shared', public.requester_admin_lane()) then false
      when not public.has_active_admin_in_lane(public.requester_admin_lane()) then false
      else true
    end,
    case
      when public.admin_lane() is not null then null
      when f.archived_at is not null or not f.public_listing or f.status <> 'active' then 'facility_inactive'
      when f.facility_classification not in ('shared', public.requester_admin_lane()) then 'facility_not_available_for_account_type'
      when not public.has_active_admin_in_lane(public.requester_admin_lane()) then
        case public.requester_admin_lane()
          when 'internal' then 'no_active_internal_admin'
          else 'no_active_external_admin'
        end
      else null
    end
  from public.facilities f
  where f.archived_at is null;
$$;

revoke all on function public.my_facility_access() from public, anon;
grant execute on function public.my_facility_access() to authenticated;

-- ---------------------------------------------------------------------
-- 2.4 Assignment-derived policies and RPCs
-- ---------------------------------------------------------------------

-- Facility configuration save: any active administrator, not an assigned one.
create or replace function public.save_facility_configuration_v2(
  p_facility_id uuid,
  p_rates jsonb,
  p_amenities jsonb,
  p_account_name text,
  p_account_number text,
  p_instructions text default '',
  p_deposit_window_minutes integer default 1440,
  p_balance_due_lead_minutes integer default 1440,
  p_correction_window_minutes integer default 1440,
  p_down_payment_percent integer default 50
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rate_item jsonb;
  amenity_item jsonb;
  method_id uuid;
  facility_name text;
  actor public.profiles%rowtype;
begin
  if not public.can_manage_facility(p_facility_id) then
    raise exception using errcode = '42501', message = 'Active administrator access required';
  end if;
  if jsonb_typeof(p_rates) <> 'array'
      or jsonb_array_length(p_rates) <> 4
      or (select count(distinct value->>'audience')
          from jsonb_array_elements(p_rates)) <> 4 then
    raise exception using errcode = '22023',
      message = 'Provide one rate for student, faculty, staff, and guest';
  end if;
  if p_amenities is not null and jsonb_typeof(p_amenities) <> 'array' then
    raise exception using errcode = '22023', message = 'Amenities must be a list';
  end if;
  if jsonb_array_length(coalesce(p_amenities, '[]'::jsonb)) <>
      (select count(distinct lower(trim(value->>'name')))
       from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))) then
    raise exception using errcode = '22023', message = 'Amenity names must be unique';
  end if;
  if p_deposit_window_minutes not between 30 and 10080
      or p_balance_due_lead_minutes not between 60 and 129600
      or p_correction_window_minutes not between 30 and 10080
      or p_down_payment_percent not between 20 and 50 then
    raise exception using errcode = '22023', message = 'Invalid payment deadline or down payment settings';
  end if;

  for rate_item in select value from jsonb_array_elements(p_rates) loop
    if rate_item->>'audience' not in ('student','faculty','staff','guest')
        or (rate_item->>'hourly_rate_centavos')::integer < 0 then
      raise exception using errcode = '22023', message = 'Invalid audience rate';
    end if;
    insert into public.facility_rates(
      facility_id, audience, hourly_rate_centavos, enabled
    ) values (
      p_facility_id,
      rate_item->>'audience',
      (rate_item->>'hourly_rate_centavos')::integer,
      true
    )
    on conflict (facility_id, audience) do update
      set hourly_rate_centavos = excluded.hourly_rate_centavos,
          enabled = true,
          updated_at = now(),
          updated_by = auth.uid();
  end loop;

  update public.facility_amenities
  set enabled = false, updated_at = now(), updated_by = auth.uid()
  where facility_id = p_facility_id;
  for amenity_item in
    select value from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))
  loop
    if length(trim(coalesce(amenity_item->>'name', ''))) not between 2 and 80
        or coalesce((amenity_item->>'price_centavos')::integer, -1) < 0
        or coalesce(amenity_item->>'pricing_unit', '')
          not in ('per_reservation','per_occurrence') then
      raise exception using errcode = '22023', message = 'Invalid facility amenity';
    end if;
    insert into public.facility_amenities(
      facility_id, name, description, price_centavos, pricing_unit, enabled
    ) values (
      p_facility_id,
      trim(amenity_item->>'name'),
      coalesce(amenity_item->>'description', ''),
      (amenity_item->>'price_centavos')::integer,
      amenity_item->>'pricing_unit',
      true
    )
    on conflict (facility_id, name) do update set
      description = excluded.description,
      price_centavos = excluded.price_centavos,
      pricing_unit = excluded.pricing_unit,
      enabled = true,
      updated_at = now(),
      updated_by = auth.uid();
  end loop;

  update public.facilities
  set deposit_window_minutes = p_deposit_window_minutes,
      balance_due_lead_minutes = p_balance_due_lead_minutes,
      payment_correction_window_minutes = p_correction_window_minutes,
      down_payment_percent = p_down_payment_percent,
      amenities = array(
        select (value->>'name')::text
        from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))
      ),
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_facility_id
  returning name::text into facility_name;

  if nullif(trim(coalesce(p_account_name, '')), '') is not null
      or nullif(trim(coalesce(p_account_number, '')), '') is not null then
    if length(trim(coalesce(p_account_name, ''))) < 2
        or length(regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g'))
          not between 10 and 15 then
      raise exception using errcode = '22023', message = 'Enter a valid GCash destination';
    end if;
    select id into method_id
    from public.facility_payment_methods
    where facility_id = p_facility_id and method_type = 'gcash' and enabled
    for update;
    if method_id is not null and exists(
      select 1 from public.facility_payment_methods m
      where m.id = method_id
        and m.account_name = trim(p_account_name)
        and m.account_number = trim(p_account_number)
        and m.instructions = trim(coalesce(p_instructions, ''))
    ) then
      null;
    else
      if method_id is not null then
        update public.facility_payment_methods
        set enabled = false, updated_at = now(), updated_by = auth.uid()
        where id = method_id;
      end if;
      insert into public.facility_payment_methods(
        facility_id, account_name, account_number, instructions
      ) values (
        p_facility_id, trim(p_account_name), trim(p_account_number),
        trim(coalesce(p_instructions, ''))
      ) returning id into method_id;
    end if;
  end if;

  select * into actor from public.profiles where id = auth.uid();
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, details, material, source_type, source_id
  ) values (
    'facility', p_facility_id, facility_name, auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    'updated pricing, amenities, and payment settings',
    jsonb_build_object(
      'rates', p_rates,
      'amenity_count', jsonb_array_length(coalesce(p_amenities, '[]'::jsonb)),
      'deposit_window_minutes', p_deposit_window_minutes,
      'balance_due_lead_minutes', p_balance_due_lead_minutes,
      'correction_window_minutes', p_correction_window_minutes,
      'down_payment_percent', p_down_payment_percent
    ), true, 'facility_configuration', gen_random_uuid()
  );

  return jsonb_build_object('facility_id', p_facility_id, 'payment_method_id', method_id);
end;
$$;

-- Payment proof submission: notify every active matching-lane admin, not
-- just facility-assigned ones.
create or replace function public.submit_payment(
  p_transaction_id uuid,p_request_id uuid,p_purpose text,p_amount_centavos integer,
  p_reference_number text,p_proof_path text,p_idempotency_key uuid
) returns public.payment_transactions
language plpgsql
security definer
set search_path=public,storage
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
  method_id uuid;
begin
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null or request_row.requester_id<>auth.uid() then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment','confirmed') then
    raise exception using errcode='22023',message='This reservation is not accepting payments';
  end if;
  if p_purpose not in ('down_payment','balance') or p_amount_centavos<=0 then
    raise exception using errcode='22023',message='Provide a valid payment amount and purpose';
  end if;
  if request_row.payment_method_id is null then
    select id into method_id from public.facility_payment_methods
    where facility_id=request_row.facility_id and enabled and method_type='gcash'
    order by updated_at desc limit 1;
    if method_id is null then
      raise exception using errcode='22023',
        message='This facility has not published a GCash account yet. Ask the administrator to configure one.';
    end if;
    update public.reservation_requests set payment_method_id=method_id where id=p_request_id;
    request_row.payment_method_id:=method_id;
  end if;
  if length(trim(p_reference_number))<6 then
    raise exception using errcode='22023',message='Provide the GCash reference number';
  end if;
  if p_proof_path not like auth.uid()::text||'/'||p_request_id::text||'/%' then
    raise exception using errcode='42501',message='Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos),0) into committed_value
  from public.payment_transactions
  where request_id=p_request_id and status in ('submitted','verified');
  if p_amount_centavos>request_row.total_amount_centavos-committed_value then
    raise exception using errcode='22023',message='Payment is greater than the outstanding balance';
  end if;
  insert into public.payment_transactions(
    id,request_id,payer_id,payment_method_id,purpose,amount_centavos,
    reference_number,proof_path,idempotency_key
  ) values (
    p_transaction_id,p_request_id,auth.uid(),request_row.payment_method_id,
    p_purpose,p_amount_centavos,trim(p_reference_number),p_proof_path,p_idempotency_key
  ) returning * into result;
  event_id:=public.reservation_event(p_request_id,'submitted payment proof',null,
    jsonb_build_object('payment_id',result.id,'purpose',result.purpose,
      'amount_centavos',result.amount_centavos),null,true);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select p.id,p_request_id,event_id,'payment_submitted','Payment needs review',
    request_row.requester_name||' submitted GCash payment proof.'
  from public.profiles p
  where p.account_status='active'
    and p.role=case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
exception when unique_violation then
  raise exception using errcode='23505',message='That payment reference or submission was already used';
end;
$$;

-- High/critical anomaly alerts: every active matching-lane admin, not just
-- facility-assigned ones.
create or replace function public.notify_anomaly_admins(
  p_anomaly_id uuid,
  p_tier text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  anomaly_row public.reservation_anomalies%rowtype;
  sent_count integer := 0;
begin
  if p_tier not in ('high', 'critical') then
    return 0;
  end if;
  select * into anomaly_row from public.reservation_anomalies where id = p_anomaly_id;
  if anomaly_row.id is null or anomaly_row.detection_mode <> 'active' then
    return 0;
  end if;

  insert into public.app_notifications(recipient_id, anomaly_id, kind, title, body)
  select
    p.id,
    anomaly_row.id,
    case when p_tier = 'critical' then 'anomaly_critical' else 'anomaly_high' end,
    case when p_tier = 'critical' then 'Critical risk signal' else 'High risk signal' end,
    anomaly_row.title || ' at ' || coalesce(f.name, 'a facility') || '. ' || anomaly_row.explanation
  from public.profiles p
  left join public.facilities f on f.id = anomaly_row.facility_id
  where p.account_status = 'active'
    and public.admin_lane(p.id) = anomaly_row.admin_lane
  on conflict do nothing;

  get diagnostics sent_count = row_count;
  return sent_count;
end;
$$;

-- Feedback and feedback notifications intentionally receive no changes here.
-- reservation_feedback_read, submit_reservation_feedback's low-rating fan-out,
-- feedback_admin_list, and feedback_admin_summary all gate the external-admin
-- branch on can_manage_facility(facility_id) -- redefined above to mean "any
-- active administrator" -- so removing the facility-assignment requirement
-- falls out of that redefinition alone. Feedback was never lane-isolated the
-- way reservations are: any active administrator (internal or external) sees
-- every facility's feedback, matching the pre-existing role/lane policy.

-- Reports and operational metrics: facility scope is now the report lane's
-- relevant classification (shared or the caller's own lane) instead of
-- facility assignment; reservation-derived figures were already restricted
-- to r.admin_lane = lane_value and needed no change.
create or replace function public.get_admin_report(
  p_from timestamptz,
  p_to timestamptz,
  p_category text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  lane_value text := public.admin_lane();
  utilisation_value jsonb;
  summary_value jsonb;
  occurrences_value jsonb;
  demand_value jsonb;
  performance_value jsonb;
begin
  if lane_value is null then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_from is null or p_to is null or p_from >= p_to
      or p_to - p_from > interval '370 days' then
    raise exception using errcode = '22023', message = 'Invalid report range';
  end if;

  with facility_scope as (
    select f.*
    from public.facilities f
    where f.archived_at is null
      and f.status = 'active'
      and f.facility_classification in ('shared', lane_value)
      and (p_category is null or f.category = p_category)
  ), open_hours as (
    select f.id, coalesce(sum(greatest(0, extract(epoch from(
      least(((d::date + f.close_time) at time zone 'Asia/Manila'), p_to) -
      greatest(((d::date + f.open_time) at time zone 'Asia/Manila'), p_from)
    )) / 3600)) filter (
      where f.open_days[extract(isodow from d)::integer]
    ), 0) available_hours
    from facility_scope f
    cross join generate_series(
      (p_from at time zone 'Asia/Manila')::date,
      ((p_to - interval '1 microsecond') at time zone 'Asia/Manila')::date,
      interval '1 day'
    ) d
    group by f.id
  ), booked as (
    select o.facility_id,
      sum(extract(epoch from (
        least(o.ends_at, p_to) - greatest(o.starts_at, p_from)
      )) / 3600) booked_hours
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    where o.booking_state = 'booked'
      and o.starts_at < p_to and o.ends_at > p_from
      and r.admin_lane = lane_value
    group by o.facility_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'facility_id', f.id,
    'facility_name', f.name::text,
    'building', f.building,
    'category', f.category,
    'booked_hours', round(coalesce(b.booked_hours, 0)::numeric, 2),
    'available_hours', round(coalesce(h.available_hours, 0)::numeric, 2),
    'fraction', case when coalesce(h.available_hours, 0) = 0 then 0
      else least(1, coalesce(b.booked_hours, 0) / h.available_hours) end
  ) order by f.name), '[]'::jsonb)
  into utilisation_value
  from facility_scope f
  left join open_hours h on h.id = f.id
  left join booked b on b.facility_id = f.id;

  select jsonb_build_object(
    'booked_hours', coalesce(sum((value->>'booked_hours')::numeric), 0),
    'available_hours', coalesce(sum((value->>'available_hours')::numeric), 0),
    'fraction', case
      when coalesce(sum((value->>'available_hours')::numeric), 0) = 0 then 0
      else least(1,
        coalesce(sum((value->>'booked_hours')::numeric), 0) /
        sum((value->>'available_hours')::numeric))
    end
  ) into summary_value
  from jsonb_array_elements(utilisation_value);

  select coalesce(jsonb_agg(jsonb_build_object(
    'occurrence_id', o.id,
    'request_id', r.id,
    'facility_id', o.facility_id,
    'requester', r.requester_name,
    'purpose', r.purpose,
    'request_status', r.status,
    'starts_at', o.starts_at,
    'ends_at', o.ends_at,
    'booked_hours', round((extract(epoch from(
      least(o.ends_at, p_to) - greatest(o.starts_at, p_from)
    )) / 3600)::numeric, 2)
  ) order by o.starts_at, o.id), '[]'::jsonb)
  into occurrences_value
  from public.reservation_occurrences o
  join public.reservation_requests r on r.id = o.request_id
  join public.facilities f on f.id = o.facility_id
  where o.booking_state = 'booked'
    and o.starts_at < p_to and o.ends_at > p_from
    and r.admin_lane = lane_value
    and (p_category is null or f.category = p_category);

  with blocks as (
    select day_number, hour_value
    from generate_series(1, 7) day_number
    cross join generate_series(7, 19, 2) hour_value
  ), clipped as (
    select o.id,
      greatest(o.starts_at, p_from) at time zone 'Asia/Manila' local_start,
      least(o.ends_at, p_to) at time zone 'Asia/Manila' local_end
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    join public.facilities f on f.id = o.facility_id
    where o.booking_state = 'booked'
      and o.starts_at < p_to and o.ends_at > p_from
      and r.admin_lane = lane_value
      and (p_category is null or f.category = p_category)
  ), occupied as (
    select distinct o.id, extract(isodow from d)::integer day_number, h.hour_value
    from clipped o
    cross join lateral generate_series(
      o.local_start::date,
      (o.local_end - interval '1 microsecond')::date,
      interval '1 day'
    ) d
    cross join lateral generate_series(7, 19, 2) h(hour_value)
    where o.local_start < d::date + make_interval(hours => h.hour_value + 2)
      and o.local_end > d::date + make_interval(hours => h.hour_value)
  ), counts as (
    select day_number, hour_value, count(*)::integer request_count
    from occupied group by 1, 2
  )
  select jsonb_agg(jsonb_build_object(
    'day', b.day_number,
    'hour', b.hour_value,
    'count', coalesce(c.request_count, 0)
  ) order by b.day_number, b.hour_value)
  into demand_value
  from blocks b left join counts c using(day_number, hour_value);

  with decisions as (
    select r.*, extract(epoch from (r.decided_at - r.created_at)) / 3600 latency_hours
    from public.reservation_requests r
    join public.facilities f on f.id = r.facility_id
    where r.created_at >= p_from and r.created_at < p_to
      and r.admin_lane = lane_value
      and (p_category is null or f.category = p_category)
  ), decided as (
    select * from decisions where decided_at is not null and latency_hours >= 0
  )
  select jsonb_build_object(
    'declined', (select count(*) from decisions where status = 'declined'),
    'over_capacity', (select count(*) from decisions where headcount > facility_capacity),
    'expired', (select count(*) from decisions where status = 'expired'),
    'median_hours', (select percentile_cont(.5) within group(order by latency_hours) from decided),
    'within_48', (select case when count(*) = 0 then null
      else count(*) filter(where latency_hours <= 48)::double precision / count(*) end from decided),
    'per_admin', '[]'::jsonb
  ) into performance_value;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'category', p_category,
    'generated_at', now(),
    'summary', summary_value,
    'utilisation', utilisation_value,
    'booked_occurrences', occurrences_value,
    'demand', demand_value,
    'performance', performance_value
  );
end;
$$;

notify pgrst, 'reload schema';
