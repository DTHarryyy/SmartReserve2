create table if not exists public.audit_entries (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('facility','reservation','account','system')),
  entity_id uuid,
  target_label text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_name text not null,
  actor_role text not null,
  action text not null,
  reason text,
  before_values jsonb not null default '{}'::jsonb,
  after_values jsonb not null default '{}'::jsonb,
  details jsonb not null default '{}'::jsonb,
  material boolean not null default true,
  source_type text,
  source_id uuid,
  created_at timestamptz not null default now(),
  unique (source_type, source_id)
);

create index if not exists audit_entries_created_idx
  on public.audit_entries(created_at desc, id desc);
create index if not exists audit_entries_entity_idx
  on public.audit_entries(entity_type, entity_id, created_at desc);
create index if not exists audit_entries_actor_idx
  on public.audit_entries(actor_id, created_at desc);
create index if not exists audit_entries_material_idx
  on public.audit_entries(created_at desc)
  where material;

alter table public.audit_entries enable row level security;
revoke all on public.audit_entries from public, anon, authenticated;
grant select on public.audit_entries to authenticated;

drop policy if exists audit_entries_select_internal_admin on public.audit_entries;
create policy audit_entries_select_internal_admin
on public.audit_entries for select to authenticated
using (public.is_internal_admin());

create or replace function public.capture_reservation_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
begin
  select * into request_row from public.reservation_requests where id = new.request_id;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, details, material, source_type, source_id, created_at
  ) values (
    'reservation', new.request_id,
    coalesce(request_row.purpose, 'Reservation') || ' — ' || coalesce(request_row.requester_name, 'Unknown requester'),
    new.actor_id, new.actor_name, new.actor_role, new.action, new.reason,
    new.details, new.material, 'reservation_event', new.id, new.created_at
  ) on conflict (source_type, source_id) do nothing;
  return new;
end;
$$;

drop trigger if exists reservation_events_capture_audit on public.reservation_events;
create trigger reservation_events_capture_audit
after insert on public.reservation_events
for each row execute procedure public.capture_reservation_audit();

create or replace function public.capture_account_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
begin
  select * into actor from public.profiles where id = new.actor_id;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, material,
    source_type, source_id, created_at
  ) values (
    'account', new.target_id, new.target_email, new.actor_id,
    coalesce(nullif(actor.full_name, ''), actor.email, 'System'),
    coalesce(actor.role, 'system'), replace(new.action, '_', ' '), new.reason,
    new.before_values, new.after_values, true,
    'account_admin_event', new.id, new.created_at
  ) on conflict (source_type, source_id) do nothing;
  return new;
end;
$$;

drop trigger if exists account_admin_events_capture_audit on public.account_admin_events;
create trigger account_admin_events_capture_audit
after insert on public.account_admin_events
for each row execute procedure public.capture_account_audit();

create or replace function public.capture_facility_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  actor_id_value uuid := auth.uid();
  action_value text;
  reason_value text := nullif(current_setting('smartreserve.audit_reason', true), '');
  material_value boolean := true;
begin
  select * into actor from public.profiles where id = actor_id_value;
  if tg_op = 'INSERT' then
    action_value := 'created';
  elsif old.archived_at is null and new.archived_at is not null then
    action_value := 'archived';
  elsif old.archived_at is not null and new.archived_at is null then
    action_value := 'restored';
  else
    action_value := 'updated';
    material_value := old.capacity is distinct from new.capacity
      or old.status is distinct from new.status
      or old.latitude is distinct from new.latitude
      or old.longitude is distinct from new.longitude
      or old.public_listing is distinct from new.public_listing
      or old.archived_at is distinct from new.archived_at;
  end if;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, material, source_type, source_id
  ) values (
    'facility', new.id, new.name::text, actor_id_value,
    coalesce(nullif(actor.full_name, ''), actor.email, new.updated_by_name, 'System'),
    coalesce(actor.role, 'system'), action_value, reason_value,
    case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end,
    to_jsonb(new), material_value, 'facility_change', gen_random_uuid()
  );
  return new;
end;
$$;

drop trigger if exists facilities_capture_audit on public.facilities;
create trigger facilities_capture_audit
after insert or update on public.facilities
for each row execute procedure public.capture_facility_audit();

insert into public.audit_entries(
  entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
  action, reason, details, material, source_type, source_id, created_at
)
select
  'reservation', e.request_id,
  r.purpose || ' — ' || r.requester_name,
  e.actor_id, e.actor_name, e.actor_role, e.action, e.reason,
  e.details, e.material, 'reservation_event', e.id, e.created_at
from public.reservation_events e
join public.reservation_requests r on r.id = e.request_id
on conflict (source_type, source_id) do nothing;

insert into public.audit_entries(
  entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
  action, reason, before_values, after_values, material,
  source_type, source_id, created_at
)
select
  'account', e.target_id, e.target_email, e.actor_id,
  coalesce(nullif(p.full_name, ''), p.email, 'System'),
  coalesce(p.role, 'system'), replace(e.action, '_', ' '), e.reason,
  e.before_values, e.after_values, true,
  'account_admin_event', e.id, e.created_at
from public.account_admin_events e
left join public.profiles p on p.id = e.actor_id
on conflict (source_type, source_id) do nothing;

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
  actor_role_value text;
  utilisation_value jsonb;
  utilisation_summary_value jsonb;
  occurrences_value jsonb;
  demand_value jsonb;
  performance_value jsonb;
begin
  select role into actor_role_value
  from public.profiles
  where id = auth.uid() and account_status = 'active';
  if actor_role_value not in ('internal_admin', 'external_admin') then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_from is null or p_to is null or p_from >= p_to or p_to - p_from > interval '370 days' then
    raise exception using errcode = '22023', message = 'Invalid report range';
  end if;

  with facility_scope as (
    select f.*
    from public.facilities f
    where f.archived_at is null
      and f.status = 'active'
      and (p_category is null or f.category = p_category)
  ), open_hours as (
    select f.id,
      coalesce(sum(greatest(0, extract(epoch from (
        least(((d::date + f.close_time) at time zone 'Asia/Manila'), p_to)
        - greatest(((d::date + f.open_time) at time zone 'Asia/Manila'), p_from)
      )) / 3600)) filter (where f.open_days[extract(isodow from d)::integer]), 0) as available_hours
    from facility_scope f
    cross join generate_series(
      (p_from at time zone 'Asia/Manila')::date,
      ((p_to - interval '1 microsecond') at time zone 'Asia/Manila')::date,
      interval '1 day'
    ) d
    group by f.id
  ), booked as (
    select o.facility_id,
      sum(extract(epoch from (least(o.ends_at, p_to) - greatest(o.starts_at, p_from))) / 3600) as booked_hours
    from public.reservation_occurrences o
    join facility_scope f on f.id = o.facility_id
    where o.booking_state = 'booked'
      and o.starts_at < p_to and o.ends_at > p_from
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
  ) order by case when coalesce(h.available_hours, 0) = 0 then 0
      else coalesce(b.booked_hours, 0) / h.available_hours end, f.name), '[]'::jsonb)
  into utilisation_value
  from facility_scope f
  left join open_hours h on h.id = f.id
  left join booked b on b.facility_id = f.id;

  select jsonb_build_object(
    'booked_hours', coalesce(sum((elem->>'booked_hours')::numeric), 0),
    'available_hours', coalesce(sum((elem->>'available_hours')::numeric), 0),
    'fraction', case
      when coalesce(sum((elem->>'available_hours')::numeric), 0) = 0 then 0
      else least(1, coalesce(sum((elem->>'booked_hours')::numeric), 0) /
        sum((elem->>'available_hours')::numeric))
    end
  ) into utilisation_summary_value
  from jsonb_array_elements(utilisation_value) elem;

  with facility_scope as (
    select f.id
    from public.facilities f
    where f.archived_at is null
      and f.status = 'active'
      and (p_category is null or f.category = p_category)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'occurrence_id', o.id,
    'request_id', r.id,
    'facility_id', o.facility_id,
    'requester', r.requester_name,
    'purpose', r.purpose,
    'request_status', r.status,
    'starts_at', o.starts_at,
    'ends_at', o.ends_at,
    'booked_hours', round((extract(epoch from (
      least(o.ends_at, p_to) - greatest(o.starts_at, p_from)
    )) / 3600)::numeric, 2)
  ) order by o.starts_at, o.id), '[]'::jsonb)
  into occurrences_value
  from public.reservation_occurrences o
  join public.reservation_requests r on r.id = o.request_id
  join facility_scope f on f.id = o.facility_id
  where o.booking_state = 'booked'
    and o.starts_at < p_to and o.ends_at > p_from;

  with blocks as (
    select day_number, hour_value
    from generate_series(1, 7) day_number
    cross join generate_series(7, 19, 2) hour_value
  ), clipped_occurrences as (
    select o.id,
      greatest(o.starts_at, p_from) at time zone 'Asia/Manila' as local_start,
      least(o.ends_at, p_to) at time zone 'Asia/Manila' as local_end
    from public.reservation_occurrences o
    join public.facilities f on f.id = o.facility_id
    where o.starts_at < p_to and o.ends_at > p_from
      and (p_category is null or f.category = p_category)
  ), occupied_blocks as (
    select distinct o.id,
      extract(isodow from d)::integer as day_number,
      h.hour_value
    from clipped_occurrences o
    cross join lateral generate_series(
      o.local_start::date,
      (o.local_end - interval '1 microsecond')::date,
      interval '1 day'
    ) d
    cross join lateral generate_series(7, 19, 2) h(hour_value)
    where o.local_start < d::date + make_interval(hours => h.hour_value + 2)
      and o.local_end > d::date + make_interval(hours => h.hour_value)
  ), counts as (
    select day_number, hour_value, count(*)::integer as request_count
    from occupied_blocks
    group by day_number, hour_value
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'day', b.day_number, 'hour', b.hour_value,
    'count', coalesce(c.request_count, 0)
  ) order by b.day_number, b.hour_value), '[]'::jsonb)
  into demand_value
  from blocks b
  left join counts c using (day_number, hour_value);

  with decisions as (
    select r.*, extract(epoch from (r.decided_at - r.created_at)) / 3600 as latency_hours
    from public.reservation_requests r
    join public.facilities f on f.id = r.facility_id
    where r.created_at >= p_from and r.created_at < p_to
      and (p_category is null or f.category = p_category)
  ), decided as (
    select * from decisions where decided_at is not null and latency_hours >= 0
  ), admins as (
    select decided_by as admin_id,
      coalesce(nullif(decided_by_name, ''), 'Unattributed') as name,
      count(*)::integer as decisions,
      percentile_cont(0.5) within group (order by latency_hours) as median_hours
    from decided
    group by decided_by, coalesce(nullif(decided_by_name, ''), 'Unattributed')
  )
  select jsonb_build_object(
    'declined', (select count(*) from decisions where status = 'declined'),
    'over_capacity', (select count(*) from decisions where headcount > facility_capacity),
    'expired', (select count(*) from decisions where status = 'expired'),
    'median_hours', (select percentile_cont(0.5) within group (order by latency_hours) from decided),
    'within_48', (select case when count(*) = 0 then null else count(*) filter (where latency_hours <= 48)::double precision / count(*) end from decided),
    'per_admin', case when actor_role_value = 'internal_admin' then
      (select coalesce(jsonb_agg(jsonb_build_object(
        'admin_id', admin_id, 'name', name, 'decisions', decisions,
        'median_hours', median_hours
      ) order by decisions desc, name), '[]'::jsonb) from admins)
      else '[]'::jsonb end
  ) into performance_value;

  return jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'category', p_category,
    'generated_at', now(),
    'summary', utilisation_summary_value,
    'utilisation', utilisation_value,
    'booked_occurrences', occurrences_value,
    'demand', demand_value,
    'performance', performance_value
  );
end;
$$;

create or replace function public.get_audit_entries(
  p_search text default null,
  p_actor text default null,
  p_entity_type text default null,
  p_material_only boolean default false,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  with filtered as (
    select a.*
    from public.audit_entries a
    where (nullif(trim(p_search), '') is null or concat_ws(' ', a.actor_name, a.target_label, a.action, a.reason, a.details::text, a.before_values::text, a.after_values::text) ilike '%' || trim(p_search) || '%')
      and (p_actor is null or a.actor_name = p_actor)
      and (p_entity_type is null or a.entity_type = p_entity_type)
      and (not p_material_only or a.material)
      and (p_from is null or a.created_at >= p_from)
      and (p_to is null or a.created_at < p_to)
  ), page as (
    select * from filtered
    where p_before_created_at is null
      or (created_at, id) < (p_before_created_at, p_before_id)
    order by created_at desc, id desc
    limit p_limit
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(page) || jsonb_build_object(
      'revertable', entity_type = 'facility' and action = 'updated'
    ) order by created_at desc, id desc) from page), '[]'::jsonb),
    'total', (select count(*) from filtered),
    'actors', coalesce((select jsonb_agg(actor_name order by actor_name) from (select distinct actor_name from filtered) actors), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

create or replace function public.record_audit_export(
  p_row_count integer,
  p_filters jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  entry_id uuid;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  select * into actor from public.profiles where id = auth.uid();
  insert into public.audit_entries(
    entity_type, target_label, actor_id, actor_name, actor_role,
    action, details, material
  ) values (
    'system', p_row_count || ' audit entries', actor.id,
    coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    'exported the audit log', jsonb_build_object('row_count', p_row_count, 'filters', p_filters), false
  ) returning id into entry_id;
  return entry_id;
end;
$$;

create or replace function public.revert_facility_audit_entry(
  p_entry_id uuid,
  p_reason text
) returns public.facilities
language plpgsql
security definer
set search_path = public
as $$
declare
  entry public.audit_entries%rowtype;
  current_row public.facilities%rowtype;
  result public.facilities%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception using errcode = '22023', message = 'A reason is required';
  end if;
  select * into entry from public.audit_entries where id = p_entry_id and entity_type = 'facility' and action = 'updated';
  if entry.id is null then raise exception using errcode = 'P0002', message = 'Reversible audit entry not found'; end if;
  select * into current_row from public.facilities where id = entry.entity_id for update;
  if current_row.updated_at::text <> entry.after_values->>'updated_at' then
    raise exception using errcode = '40001', message = 'This facility changed after the selected audit entry';
  end if;
  perform set_config('smartreserve.audit_reason', trim(p_reason), true);
  update public.facilities set
    capacity = case when entry.before_values->'capacity' is distinct from entry.after_values->'capacity' then (entry.before_values->>'capacity')::integer else capacity end,
    status = case when entry.before_values->'status' is distinct from entry.after_values->'status' then entry.before_values->>'status' else status end,
    latitude = case when entry.before_values->'latitude' is distinct from entry.after_values->'latitude' then (entry.before_values->>'latitude')::double precision else latitude end,
    longitude = case when entry.before_values->'longitude' is distinct from entry.after_values->'longitude' then (entry.before_values->>'longitude')::double precision else longitude end,
    accuracy = case when entry.before_values->'accuracy' is distinct from entry.after_values->'accuracy' then (entry.before_values->>'accuracy')::integer else accuracy end,
    public_listing = case when entry.before_values->'public_listing' is distinct from entry.after_values->'public_listing' then (entry.before_values->>'public_listing')::boolean else public_listing end
  where id = entry.entity_id
  returning * into result;
  return result;
end;
$$;

revoke all on function public.get_admin_report(timestamptz,timestamptz,text) from public, anon;
grant execute on function public.get_admin_report(timestamptz,timestamptz,text) to authenticated;
grant execute on function public.get_audit_entries(text,text,text,boolean,timestamptz,timestamptz,timestamptz,uuid,integer) to authenticated;
grant execute on function public.record_audit_export(integer,jsonb) to authenticated;
grant execute on function public.revert_facility_audit_entry(uuid,text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'audit_entries'
  ) then
    alter publication supabase_realtime add table public.audit_entries;
  end if;
end $$;

notify pgrst, 'reload schema';
