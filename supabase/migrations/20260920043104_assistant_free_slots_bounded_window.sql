-- Generate slots inside the window the caller asked about.
--
-- Without this, assistant_available_facilities silently lost rooms. The slot
-- limit is a token budget, and it was being spent walking the morning: a room
-- free from 8am filled its twelve slots by 1:30pm, so an afternoon query saw
-- at most the first two afternoon slots -- and a room free from 7am reached
-- only 12:30pm and was reported as having nothing free on a day it was empty.
--
-- Reporting a free room as busy is the same class of error as inventing
-- availability, so the window now bounds generation rather than filtering
-- afterwards. Two new reason codes fall out of it: 'no_time_in_window' when
-- the requested hours are shorter than the requested booking, and
-- 'fully_booked' when the window exists but nothing in it is free.

create or replace function public.assistant_facility_free_slots(
  p_facility_id uuid,
  p_day date,
  p_duration_hours numeric default 1,
  p_limit integer default 6,
  p_from_hour numeric default null,
  p_to_hour numeric default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  facility_row public.facilities%rowtype;
  lane_value text;
  limit_value integer := least(greatest(coalesce(p_limit, 6), 1), 12);
  duration numeric := coalesce(p_duration_hours, 1);
  step constant numeric := 0.5;
  today_manila date := (now() at time zone 'Asia/Manila')::date;
  day_epoch numeric;
  now_hour numeric;
  buffer_hours numeric;
  open_hour numeric;
  close_hour numeric;
  weekday_index integer;
  lo numeric;
  hi numeric;
  slot_start numeric;
  slot_end numeric;
  clashes boolean;
  slots jsonb := '[]'::jsonb;
  busy_starts numeric[] := '{}';
  busy_ends numeric[] := '{}';
  bookable boolean;
  block_reason text;
  unavailable text := null;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_day is null then
    raise exception using errcode = '22023', message = 'A day is required';
  end if;

  select * into facility_row
  from public.facilities
  where id = p_facility_id and archived_at is null;

  if facility_row.id is null then
    raise exception using errcode = '22023', message = 'Facility not found';
  end if;

  lane_value := public.requester_admin_lane();

  bookable :=
    facility_row.status = 'active'
    and facility_row.public_listing
    and facility_row.facility_classification in ('shared', lane_value)
    and public.has_active_admin_in_lane(lane_value);

  block_reason := case
    when facility_row.status <> 'active' then 'facility_inactive'
    when facility_row.facility_classification not in ('shared', lane_value)
      then 'facility_not_available_for_account_type'
    when not public.has_active_admin_in_lane(lane_value)
      then 'no_active_' || lane_value || '_admin'
    else null
  end;

  open_hour := extract(hour from facility_row.open_time)
    + extract(minute from facility_row.open_time) / 60.0;
  close_hour := extract(hour from facility_row.close_time)
    + extract(minute from facility_row.close_time) / 60.0;

  -- open_days is a Monday-first boolean[7]; isodow is 1..7 Monday-first too.
  weekday_index := extract(isodow from p_day)::integer;

  -- Each reason is reported rather than silently returning an empty list, so
  -- the model can say WHY there is nothing instead of guessing.
  if not bookable then
    unavailable := coalesce(block_reason, 'facility_unavailable');
  elsif duration <= 0 then
    unavailable := 'invalid_duration';
  elsif round(duration * 60) > facility_row.max_duration_minutes then
    unavailable := 'exceeds_max_duration';
  elsif p_day < today_manila then
    unavailable := 'day_in_past';
  elsif p_day > today_manila + facility_row.advance_booking_days then
    unavailable := 'beyond_advance_window';
  elsif not coalesce(facility_row.open_days[weekday_index], false) then
    unavailable := 'closed_that_day';
  end if;

  if unavailable is null then
    -- The search window: opening hours, narrowed by any hours the caller
    -- named, and never starting in the past.
    lo := greatest(open_hour, coalesce(p_from_hour, open_hour));
    hi := least(close_hour, coalesce(p_to_hour, close_hour));

    if p_day = today_manila then
      now_hour := extract(hour from (now() at time zone 'Asia/Manila'))
        + extract(minute from (now() at time zone 'Asia/Manila')) / 60.0;
      lo := greatest(lo, ceil(now_hour / step) * step);
    end if;

    -- Keep the grid anchored to opening time so the offsets a caller sees
    -- match the booking form's, whatever window was asked for.
    lo := open_hour + ceil((lo - open_hour) / step) * step;

    if hi - lo < duration then
      unavailable := 'no_time_in_window';
    else
      buffer_hours := (2 * facility_row.booking_buffer_minutes) / 60.0;
      day_epoch := extract(epoch from p_day::timestamp);

      -- Busy windows come from facility_busy_windows, the same source the
      -- booking form uses; it applies lane visibility itself. Hours are
      -- offsets from local midnight, so a window may fall outside 0..24 once
      -- inflated -- that is correct and the overlap test handles it.
      select
        coalesce(array_agg(
          (extract(epoch from (b.starts_at at time zone 'Asia/Manila')) - day_epoch)
            / 3600.0 - buffer_hours
          order by b.starts_at), '{}'),
        coalesce(array_agg(
          (extract(epoch from (b.ends_at at time zone 'Asia/Manila')) - day_epoch)
            / 3600.0 + buffer_hours
          order by b.starts_at), '{}')
      into busy_starts, busy_ends
      from public.facility_busy_windows(
        array[p_facility_id],
        (p_day::timestamp at time zone 'Asia/Manila'),
        ((p_day + 1)::timestamp at time zone 'Asia/Manila')
      ) b;

      slot_start := lo;
      while slot_start + duration <= hi
        and jsonb_array_length(slots) < limit_value
      loop
        slot_end := slot_start + duration;

        select exists (
          select 1
          from unnest(busy_starts, busy_ends) as w(busy_start, busy_end)
          where w.busy_start < slot_end and slot_start < w.busy_end
        ) into clashes;

        if not clashes then
          slots := slots || jsonb_build_array(jsonb_build_object(
            'start_hour', slot_start::float8,
            'end_hour', slot_end::float8,
            'label',
              public.assistant_format_clock_hour(slot_start) || ' - ' ||
              public.assistant_format_clock_hour(slot_end)
          ));
        end if;

        slot_start := slot_start + step;
      end loop;

      if jsonb_array_length(slots) = 0 then
        unavailable := 'fully_booked';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'facility_id', facility_row.id,
    'facility_name', facility_row.name,
    'day', to_char(p_day, 'FMDay, FMDD Mon YYYY'),
    'day_iso', p_day,
    'duration_hours', duration::float8,
    'open_time', public.assistant_format_clock_hour(open_hour),
    'close_time', public.assistant_format_clock_hour(close_hour),
    'bookable_for_me', bookable,
    'booking_block_reason', block_reason,
    'unavailable_reason', unavailable,
    'free_slots', slots
  );
end;
$$;

-- Push the window down into slot generation instead of filtering the result.
create or replace function public.assistant_available_facilities(
  p_day date,
  p_start_hour numeric default null,
  p_end_hour numeric default null,
  p_duration_hours numeric default 1,
  p_min_capacity integer default null,
  p_category text default null,
  p_limit integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  lane_value text;
  limit_value integer := least(greatest(coalesce(p_limit, 5), 1), 10);
  duration numeric := greatest(coalesce(p_duration_hours, 1), 0.5);
  window_start numeric := p_start_hour;
  window_end numeric := p_end_hour;
  facility_row record;
  slot_payload jsonb;
  results jsonb := '[]'::jsonb;
  considered integer := 0;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_day is null then
    raise exception using errcode = '22023', message = 'A day is required';
  end if;

  -- A window narrower than the requested booking cannot contain it. Trust the
  -- window -- the user named the hours they care about -- and shorten the
  -- booking to fit rather than returning nothing.
  if window_start is not null and window_end is not null
    and window_end - window_start < duration then
    duration := greatest(window_end - window_start, 0.5);
  end if;

  lane_value := public.requester_admin_lane();

  for facility_row in
    select f.id, f.name, f.building, f.room, f.category, f.capacity
    from public.facilities f
    where f.archived_at is null
      and f.status = 'active'
      and f.public_listing
      and f.facility_classification in ('shared', lane_value)
      and (p_min_capacity is null or f.capacity >= p_min_capacity)
      and (p_category is null or f.category = p_category)
      and public.has_active_admin_in_lane(lane_value)
    order by f.capacity asc, f.name asc
    -- Bounded so a large catalogue cannot turn one question into an
    -- unbounded scan of per-facility slot computations.
    limit 40
  loop
    exit when jsonb_array_length(results) >= limit_value;
    considered := considered + 1;

    -- Three slots is enough to prove the room is open and to let the user
    -- pick; every half-hour offset after that is tokens for no decision.
    slot_payload := public.assistant_facility_free_slots(
      facility_row.id, p_day, duration, 3, window_start, window_end
    );

    if jsonb_array_length(slot_payload -> 'free_slots') > 0 then
      results := results || jsonb_build_array(jsonb_build_object(
        'id', facility_row.id,
        'name', facility_row.name,
        'building', facility_row.building,
        'room', facility_row.room,
        'category', facility_row.category,
        'capacity', facility_row.capacity,
        'free_slots', slot_payload -> 'free_slots'
      ));
    end if;
  end loop;

  return jsonb_build_object(
    'day', to_char(p_day, 'FMDay, FMDD Mon YYYY'),
    'day_iso', p_day,
    'duration_hours', duration::float8,
    'requested_window', case
      when window_start is null then null
      else public.assistant_format_clock_hour(window_start) || ' - ' ||
           public.assistant_format_clock_hour(coalesce(window_end, 24))
    end,
    'facilities_considered', considered,
    'facilities', results
  );
end;
$$;

revoke execute on function public.assistant_facility_free_slots(uuid, date, numeric, integer, numeric, numeric)
  from public, anon;
grant execute on function public.assistant_facility_free_slots(uuid, date, numeric, integer, numeric, numeric)
  to authenticated;

notify pgrst, 'reload schema';
