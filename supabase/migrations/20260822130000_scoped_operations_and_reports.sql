-- Close the remaining operational read paths around the same facility + lane
-- boundary used by reservation RLS and action RPCs.

-- Remove historical administrator notifications created by the former global
-- fan-out. Requester notifications remain untouched.
delete from public.app_notifications notification
using public.reservation_requests request, public.profiles recipient
where notification.request_id = request.id
  and notification.recipient_id = recipient.id
  and recipient.role in ('internal_admin', 'external_admin')
  and not public.can_manage_reservation(request.id, recipient.id);

create or replace function public.get_external_clients()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare result_value jsonb;
begin
  if public.admin_lane() <> 'external' then
    raise exception using errcode = '42501',
      message = 'External administrator access required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'email', p.email,
    'full_name', coalesce(nullif(p.full_name, ''), p.email),
    'role', 'user',
    'account_status', p.account_status,
    'created_at', p.created_at,
    'reservation_count', metrics.reservation_count,
    'last_reservation_at', metrics.last_reservation_at
  ) order by metrics.last_reservation_at desc, p.created_at desc), '[]'::jsonb)
  into result_value
  from public.profiles p
  join lateral (
    select count(*)::integer reservation_count, max(r.created_at) last_reservation_at
    from public.reservation_requests r
    where r.requester_id = p.id
      and r.admin_lane = 'external'
      and public.can_manage_reservation(r.id)
  ) metrics on metrics.reservation_count > 0
  where p.role = 'user';

  return result_value;
end;
$$;

revoke all on function public.get_external_clients() from public, anon;
grant execute on function public.get_external_clients() to authenticated;

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
      and public.can_manage_facility(f.id)
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
      and public.can_manage_facility(o.facility_id)
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
    and public.can_manage_facility(o.facility_id)
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
      and public.can_manage_facility(o.facility_id)
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
      and public.can_manage_facility(r.facility_id)
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

revoke all on function public.get_admin_report(timestamptz, timestamptz, text)
  from public, anon;
grant execute on function public.get_admin_report(timestamptz, timestamptz, text)
  to authenticated;

create or replace function public.facility_busy_windows(
  p_facility_ids uuid[],
  p_from timestamptz,
  p_to timestamptz
) returns table (
  facility_id uuid,
  starts_at timestamptz,
  ends_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select o.facility_id, o.starts_at, o.ends_at
  from public.reservation_occurrences o
  join public.facilities f on f.id = o.facility_id
  where p_to > p_from
    and p_to <= p_from + interval '120 days'
    and array_length(p_facility_ids, 1) between 1 and 40
    and o.facility_id = any(p_facility_ids)
    and o.booking_state in ('held', 'booked')
    and f.archived_at is null
    and f.public_listing
    and public.has_facility_admin_lane(f.id, public.requester_admin_lane())
    and tstzrange(o.starts_at, o.ends_at, '[)')
      && tstzrange(p_from, p_to, '[)')
  order by o.facility_id, o.starts_at;
$$;

revoke all on function public.facility_busy_windows(uuid[], timestamptz, timestamptz)
  from public, anon;
grant execute on function public.facility_busy_windows(uuid[], timestamptz, timestamptz)
  to authenticated;

notify pgrst, 'reload schema';
