-- Free-slot computation is the assistant's defence against inventing
-- availability, so what matters is that it exists with the right shape, that
-- only a signed-in caller can reach it, and that every way of having nothing
-- to offer is reported as its own reason rather than as an empty list the
-- model is free to explain however it likes.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(16);

select has_function('public', 'assistant_facility_free_slots',
  array['uuid', 'date', 'numeric', 'integer', 'numeric', 'numeric'],
  'assistant_facility_free_slots exists');
select has_function('public', 'assistant_available_facilities',
  array['date', 'numeric', 'numeric', 'numeric', 'integer', 'text', 'integer'],
  'assistant_available_facilities exists');
select has_function('public', 'assistant_format_clock_hour',
  array['numeric'],
  'assistant_format_clock_hour exists');

-- Read paths a signed-in user is meant to call directly, unlike the rate
-- limiter and the telemetry writer.
select ok(
  has_function_privilege('authenticated',
    'public.assistant_facility_free_slots(uuid, date, numeric, integer, numeric, numeric)',
    'execute'),
  'a signed-in client may ask when a room is free'
);
select ok(
  has_function_privilege('authenticated',
    'public.assistant_available_facilities(date, numeric, numeric, numeric, integer, text, integer)',
    'execute'),
  'a signed-in client may ask what is free on a day'
);
select ok(
  not has_function_privilege('anon',
    'public.assistant_facility_free_slots(uuid, date, numeric, integer, numeric, numeric)',
    'execute'),
  'an anonymous caller cannot read the schedule'
);
select ok(
  not has_function_privilege('anon',
    'public.assistant_available_facilities(date, numeric, numeric, numeric, integer, text, integer)',
    'execute'),
  'an anonymous caller cannot enumerate free facilities'
);

-- The clock formatter is what the model repeats verbatim, so its output is
-- part of the contract, not an implementation detail.
select is(public.assistant_format_clock_hour(7), '7:00 AM',
  'a whole morning hour reads as the app shows it');
select is(public.assistant_format_clock_hour(13.5), '1:30 PM',
  'a half hour past noon reads in 12-hour form');
select is(public.assistant_format_clock_hour(0), '12:00 AM',
  'midnight is not rendered as hour zero');

-- Reason codes. Each of these is a different sentence the assistant has to be
-- able to say; collapsing them into "nothing free" is what invites a guess.
create temp table free_slot_actor as
select id as user_id from public.profiles
where account_status = 'active'
order by created_at limit 1;

create temp table free_slot_facility as
select id as facility_id, open_days, advance_booking_days, max_duration_minutes
from public.facilities
where archived_at is null and status = 'active' and public_listing
order by name limit 1;

select ok((select user_id is not null from free_slot_actor),
  'the fixture found an account to ask as');
select ok((select facility_id is not null from free_slot_facility),
  'the fixture found a bookable facility');

-- Identity has to be present as a JWT claim, not just a role: every one of
-- these functions refuses a caller whose auth.uid() is null, which is the
-- point of them.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', user_id, 'role', 'authenticated')::text,
  true
) from free_slot_actor;
set local role authenticated;

select is(
  (select public.assistant_facility_free_slots(
     (select facility_id from free_slot_facility),
     current_date - 1, 1, 6, null, null) ->> 'unavailable_reason'),
  'day_in_past',
  'a day that has gone says so'
);

select is(
  (select public.assistant_facility_free_slots(
     (select facility_id from free_slot_facility),
     current_date + (select advance_booking_days from free_slot_facility) + 5,
     1, 6, null, null) ->> 'unavailable_reason'),
  'beyond_advance_window',
  'a day past the advance window says so'
);

select is(
  (select public.assistant_facility_free_slots(
     (select facility_id from free_slot_facility),
     current_date + 1,
     (select max_duration_minutes from free_slot_facility) / 60.0 + 2,
     6, null, null) ->> 'unavailable_reason'),
  'exceeds_max_duration',
  'a booking longer than the facility allows says so'
);

-- A two-hour booking cannot fit in a one-hour window. This is the case that
-- used to return nothing at all, because the window was read as the duration.
select is(
  (select public.assistant_facility_free_slots(
     (select facility_id from free_slot_facility),
     current_date + 1, 2, 6, 9, 10) ->> 'unavailable_reason'),
  'no_time_in_window',
  'a window narrower than the booking says so'
);

reset role;

select * from finish();
rollback;
