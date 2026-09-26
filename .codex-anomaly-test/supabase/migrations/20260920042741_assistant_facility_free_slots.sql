-- Free slots, computed in Postgres.
--
-- The assistant's availability tool previously handed the model a list of
-- BUSY windows and left it to work out what was free. That is arithmetic on
-- schedule data, which is exactly the class of work the model must never do:
-- a plausible subtraction is indistinguishable from a correct one, and the
-- user acts on the answer. These functions return the bookable windows
-- themselves, so the model can only repeat a list it was given.
--
-- The rules are a faithful port of freeSlotsForDay in
-- lib/features/assistant/assistant_availability.dart. They must stay in step:
-- if chat and the booking form disagree about whether 2pm is free, the chat
-- is wrong by definition, because the booking form is what actually submits.
--
-- Two details carried over deliberately:
--
--   * The buffer is inflated by 2 x booking_buffer_minutes on EACH edge of a
--     busy window, matching _inflate in that file. With the 15-minute default
--     this leaves a 30-minute gap either side of an existing booking -- the
--     buffer owed to the reservation that ends and the one that begins.
--
--   * Slots start on a half-hour grid, and on the current day the first
--     candidate is rounded UP to the next grid point after now. Offering a
--     slot that started ten minutes ago is worse than offering none.
--
-- Everything is evaluated in Asia/Manila, which is the only wall clock
-- SmartReserve books against.

-- ---------------------------------------------------------------------------
-- assistant_format_clock_hour: 13.5 -> "1:30 PM".
--
-- Mirrors the half-hour grid of formatClockHour in assistant_availability.dart
-- but renders the 12-hour form the app shows a user, because this string is
-- spoken by the assistant rather than fed back into a picker.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_format_clock_hour(p_hours numeric)
returns text
language sql
immutable
as $$
  select to_char(
    date '2000-01-01' + make_interval(mins => round(p_hours * 60)::integer),
    'FMHH12:MI AM'
  );
$$;

-- ---------------------------------------------------------------------------
-- assistant_facility_free_slots: when can I have THIS room on THIS day?
-- ---------------------------------------------------------------------------
create or replace function public.assistant_facility_free_slots(
  p_facility_id uuid,
  p_day date,
  p_duration_hours numeric default 1,
  p_limit integer default 6
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
    lo := open_hour;
    if p_day = today_manila then
      now_hour := extract(hour from (now() at time zone 'Asia/Manila'))
        + extract(minute from (now() at time zone 'Asia/Manila')) / 60.0;
      lo := greatest(lo, ceil(now_hour / step) * step);
    end if;

    buffer_hours := (2 * facility_row.booking_buffer_minutes) / 60.0;
    day_epoch := extract(epoch from p_day::timestamp);

    -- Busy windows come from facility_busy_windows, the same source the
    -- booking form uses; it applies lane visibility itself. Hours are offsets
    -- from local midnight, so a window may fall outside 0..24 once inflated --
    -- that is correct and the overlap test handles it.
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
    while slot_start + duration <= close_hour
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
          'start_hour', slot_start,
          'end_hour', slot_end,
          'label',
            public.assistant_format_clock_hour(slot_start) || ' - ' ||
            public.assistant_format_clock_hour(slot_end)
        ));
      end if;

      slot_start := slot_start + step;
    end loop;
  end if;

  return jsonb_build_object(
    'facility_id', facility_row.id,
    'facility_name', facility_row.name,
    'day', to_char(p_day, 'FMDay, FMDD Mon YYYY'),
    'day_iso', p_day,
    'duration_hours', duration,
    'open_time', public.assistant_format_clock_hour(open_hour),
    'close_time', public.assistant_format_clock_hour(close_hour),
    'bookable_for_me', bookable,
    'booking_block_reason', block_reason,
    'unavailable_reason', unavailable,
    'free_slots', slots
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- assistant_available_facilities: what can I book on Friday afternoon?
--
-- The catalogue filter of assistant_recommend_facilities, narrowed to rooms
-- that actually have a free window on the requested day. Answering this by
-- composing the two existing tools is not possible inside the assistant's
-- 2-round, 3-call-per-round ceiling once there is more than a handful of
-- candidates, so it is one call.
--
-- Ordering stays capacity-then-name, as in assistant_recommend_facilities:
-- the ranking that decides which room is "best" belongs to
-- assistant_recommendation.dart and must not be duplicated here.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_available_facilities(
  p_day date,
  p_start_hour numeric default null,
  p_end_hour numeric default null,
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
  duration numeric;
  facility_row record;
  slot_payload jsonb;
  slot jsonb;
  matching jsonb;
  results jsonb := '[]'::jsonb;
  considered integer := 0;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_day is null then
    raise exception using errcode = '22023', message = 'A day is required';
  end if;

  lane_value := public.requester_admin_lane();

  -- A requested window sets the duration; otherwise look for an hour.
  if p_start_hour is not null and p_end_hour is not null
    and p_end_hour > p_start_hour then
    duration := p_end_hour - p_start_hour;
  else
    duration := 1;
  end if;

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

    slot_payload := public.assistant_facility_free_slots(
      facility_row.id, p_day, duration, 6
    );

    matching := '[]'::jsonb;
    for slot in select * from jsonb_array_elements(slot_payload -> 'free_slots')
    loop
      -- With a requested window, keep only slots that sit inside it; the
      -- caller asked about Friday afternoon, not Friday.
      if p_start_hour is null
        or ((slot ->> 'start_hour')::numeric >= p_start_hour
            and (slot ->> 'end_hour')::numeric <= coalesce(p_end_hour, 24))
      then
        matching := matching || jsonb_build_array(slot);
      end if;
    end loop;

    if jsonb_array_length(matching) > 0 then
      results := results || jsonb_build_array(jsonb_build_object(
        'id', facility_row.id,
        'name', facility_row.name,
        'building', facility_row.building,
        'room', facility_row.room,
        'category', facility_row.category,
        'capacity', facility_row.capacity,
        'free_slots', matching
      ));
    end if;
  end loop;

  return jsonb_build_object(
    'day', to_char(p_day, 'FMDay, FMDD Mon YYYY'),
    'day_iso', p_day,
    'duration_hours', duration,
    'requested_window', case
      when p_start_hour is null then null
      else public.assistant_format_clock_hour(p_start_hour) || ' - ' ||
           public.assistant_format_clock_hour(coalesce(p_end_hour, 24))
    end,
    'facilities_considered', considered,
    'facilities', results
  );
end;
$$;

revoke execute on function public.assistant_format_clock_hour(numeric)
  from public, anon;
grant execute on function public.assistant_format_clock_hour(numeric)
  to authenticated;

revoke execute on function public.assistant_facility_free_slots(uuid, date, numeric, integer)
  from public, anon;
grant execute on function public.assistant_facility_free_slots(uuid, date, numeric, integer)
  to authenticated;

revoke execute on function public.assistant_available_facilities(date, numeric, numeric, integer, text, integer)
  from public, anon;
grant execute on function public.assistant_available_facilities(date, numeric, numeric, integer, text, integer)
  to authenticated;

notify pgrst, 'reload schema';
