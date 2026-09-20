-- Emit slot hours as float8 rather than numeric.
--
-- jsonb renders numeric at full scale, so a 7am slot arrived at the model as
-- 7.00000000000000000000. Availability is one of the commonest questions the
-- assistant answers, and every one of those zeros is an input token paid for
-- on a value that is only ever read to two decimal places.
--
-- Only the two slot bounds and the duration change; everything else is
-- reproduced verbatim from 20260920042741_assistant_facility_free_slots.sql
-- because plpgsql bodies are replaced whole.

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

  weekday_index := extract(isodow from p_day)::integer;

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
          'start_hour', slot_start::float8,
          'end_hour', slot_end::float8,
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

notify pgrst, 'reload schema';
