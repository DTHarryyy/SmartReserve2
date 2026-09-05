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
  report_value jsonb;
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
  ), scoped_occurrences as (
    select
      o.id as occurrence_id,
      o.request_id,
      o.facility_id,
      r.requester_name,
      r.purpose,
      r.status as request_status,
      o.starts_at,
      o.ends_at,
      greatest(o.starts_at, p_from) as clipped_starts_at,
      least(o.ends_at, p_to) as clipped_ends_at,
      extract(epoch from (least(o.ends_at, p_to) - greatest(o.starts_at, p_from))) / 3600 as clipped_hours
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    join facility_scope f on f.id = o.facility_id
    where o.booking_state = 'booked'
      and o.starts_at < p_to
      and o.ends_at > p_from
      and r.admin_lane = lane_value
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
  ), utilisation as (
    select
      f.id as facility_id,
      f.name::text as facility_name,
      f.building,
      f.category,
      round(coalesce(sum(o.clipped_hours), 0)::numeric, 2) as booked_hours,
      round(coalesce(h.available_hours, 0)::numeric, 2) as available_hours
    from facility_scope f
    left join open_hours h on h.id = f.id
    left join scoped_occurrences o on o.facility_id = f.id
    group by f.id, f.name, f.building, f.category, h.available_hours
  ), summary as (
    select
      coalesce(sum(u.booked_hours), 0)::numeric as booked_hours,
      coalesce(sum(u.available_hours), 0)::numeric as available_hours
    from utilisation u
  ), demand as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'day', b.day_number,
      'hour', b.hour_value,
      'count', coalesce(c.request_count, 0)
    ) order by b.day_number, b.hour_value), '[]'::jsonb) as value
    from (
      select day_number, hour_value
      from generate_series(1, 7) day_number
      cross join generate_series(7, 19, 2) hour_value
    ) b
    left join (
      select day_number, hour_value, count(*)::integer as request_count
      from (
        select distinct
          o.occurrence_id,
          extract(isodow from d)::integer as day_number,
          h.hour_value
        from scoped_occurrences o
        cross join lateral generate_series(
          (o.clipped_starts_at at time zone 'Asia/Manila')::date,
          ((o.clipped_ends_at - interval '1 microsecond') at time zone 'Asia/Manila')::date,
          interval '1 day'
        ) d
        cross join lateral generate_series(7, 19, 2) h(hour_value)
        where (o.clipped_starts_at at time zone 'Asia/Manila') <
            d::date + make_interval(hours => h.hour_value + 2)
          and (o.clipped_ends_at at time zone 'Asia/Manila') >
            d::date + make_interval(hours => h.hour_value)
      ) occupied
      group by day_number, hour_value
    ) c using(day_number, hour_value)
  ), performance_scope as (
    select
      r.*,
      extract(epoch from (r.decided_at - r.created_at)) / 3600 as latency_hours
    from public.reservation_requests r
    join facility_scope f on f.id = r.facility_id
    where r.created_at >= p_from
      and r.created_at < p_to
      and r.admin_lane = lane_value
  ), decided as (
    select * from performance_scope
    where decided_at is not null and latency_hours >= 0
  ), per_admin as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'admin_id', admin_id,
      'name', name,
      'decisions', decisions,
      'median_hours', median_hours
    ) order by decisions desc, name), '[]'::jsonb) as value
    from (
      select
        decided_by as admin_id,
        coalesce(nullif(decided_by_name, ''), 'Unattributed') as name,
        count(*)::integer as decisions,
        percentile_cont(.5) within group(order by latency_hours) as median_hours
      from decided
      group by decided_by, coalesce(nullif(decided_by_name, ''), 'Unattributed')
    ) rows
  )
  select jsonb_build_object(
    'contract_version', 2,
    'from', p_from,
    'to', p_to,
    'category', p_category,
    'generated_at', now(),
    'summary', jsonb_build_object(
      'booked_hours', s.booked_hours,
      'available_hours', s.available_hours,
      'fraction', case when s.available_hours = 0 then 0
        else least(1::numeric, s.booked_hours / s.available_hours) end
    ),
    'utilisation', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'facility_id', u.facility_id,
        'facility_name', u.facility_name,
        'building', u.building,
        'category', u.category,
        'booked_hours', u.booked_hours,
        'available_hours', u.available_hours,
        'fraction', case when u.available_hours = 0 then 0
          else least(1::numeric, u.booked_hours / u.available_hours) end
      ) order by u.facility_name), '[]'::jsonb)
      from utilisation u
    ),
    'booked_occurrences', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'occurrence_id', o.occurrence_id,
        'request_id', o.request_id,
        'facility_id', o.facility_id,
        'requester', o.requester_name,
        'purpose', o.purpose,
        'request_status', o.request_status,
        'starts_at', o.starts_at,
        'ends_at', o.ends_at,
        'booked_hours', round(o.clipped_hours::numeric, 2)
      ) order by o.starts_at, o.occurrence_id), '[]'::jsonb)
      from scoped_occurrences o
    ),
    'demand', (select value from demand),
    'performance', jsonb_build_object(
      'declined', (select count(*) from performance_scope where status = 'declined'),
      'over_capacity', (select count(*) from performance_scope where headcount > facility_capacity),
      'expired', (select count(*) from performance_scope where status = 'expired'),
      'median_hours', (select percentile_cont(.5) within group(order by latency_hours) from decided),
      'within_48', (select case when count(*) = 0 then null
        else count(*) filter(where latency_hours <= 48)::double precision / count(*) end from decided),
      'per_admin', (select value from per_admin)
    )
  ) into report_value
  from summary s;

  return report_value;
end;
$$;

revoke all on function public.get_admin_report(timestamptz, timestamptz, text)
from public, anon;
grant execute on function public.get_admin_report(timestamptz, timestamptz, text)
to authenticated;

notify pgrst, 'reload schema';
