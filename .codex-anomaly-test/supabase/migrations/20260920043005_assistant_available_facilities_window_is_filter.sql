-- The requested window filters slots; it does not dictate their length.
--
-- "What is available Friday afternoon?" asks which rooms have SOME bookable
-- time between 1pm and 5pm. Reading the window as the duration turned it into
-- "which rooms are free for one unbroken four-hour block", which answers a
-- question nobody asked and returns nothing on a lightly booked day.
--
-- Duration is now its own parameter, defaulting to an hour, so the window and
-- the length of the booking stay independent. The parameter list changes, so
-- the previous signature is dropped rather than replaced.

drop function if exists public.assistant_available_facilities(date, numeric, numeric, integer, text, integer);

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
  window_end numeric := coalesce(p_end_hour, 24);
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

  -- A window narrower than the requested booking cannot contain it. Trust the
  -- window -- the user named the hours they care about -- and shorten the
  -- booking to fit rather than returning nothing.
  if window_start is not null and window_end - window_start < duration then
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
    limit 40
  loop
    exit when jsonb_array_length(results) >= limit_value;
    considered := considered + 1;

    slot_payload := public.assistant_facility_free_slots(
      facility_row.id, p_day, duration, 12
    );

    matching := '[]'::jsonb;
    for slot in select * from jsonb_array_elements(slot_payload -> 'free_slots')
    loop
      if window_start is null
        or ((slot ->> 'start_hour')::numeric >= window_start
            and (slot ->> 'end_hour')::numeric <= window_end)
      then
        -- Three is enough to prove the room is open and to let the user pick;
        -- a full list of every half-hour offset is tokens for no decision.
        if jsonb_array_length(matching) < 3 then
          matching := matching || jsonb_build_array(slot);
        end if;
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
    'duration_hours', duration::float8,
    'requested_window', case
      when window_start is null then null
      else public.assistant_format_clock_hour(window_start) || ' - ' ||
           public.assistant_format_clock_hour(window_end)
    end,
    'facilities_considered', considered,
    'facilities', results
  );
end;
$$;

revoke execute on function public.assistant_available_facilities(date, numeric, numeric, numeric, integer, text, integer)
  from public, anon;
grant execute on function public.assistant_available_facilities(date, numeric, numeric, numeric, integer, text, integer)
  to authenticated;

notify pgrst, 'reload schema';
