begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(9);

create temp table check_in_window_test as
select
  (select id from public.profiles where email = 'user@csu.edu.ph') requester_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) internal_admin_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

delete from public.reservation_requests
where id in (
  '98000000-0000-0000-0000-000000000001',
  '98000000-0000-0000-0000-000000000002',
  '98000000-0000-0000-0000-000000000003',
  '98000000-0000-0000-0000-000000000004',
  '98000000-0000-0000-0000-000000000005'
);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, version, created_at
)
select id, requester_id, facility_id, 'Check-in Window Guest', 'user',
  'Computer Laboratory 1', 'CICS', 40, purpose, 10,
  'approved', 'confirmed', 'internal', 'guest', 1, now()
from check_in_window_test,
(values
  ('98000000-0000-0000-0000-000000000001'::uuid, 'Late by 20 minutes'),
  ('98000000-0000-0000-0000-000000000002'::uuid, 'Window already closed'),
  ('98000000-0000-0000-0000-000000000003'::uuid, 'On time'),
  ('98000000-0000-0000-0000-000000000004'::uuid, 'No-show attempted too early'),
  ('98000000-0000-0000-0000-000000000005'::uuid, 'No-show after grace')
) as rows(id, purpose);

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select occurrence_id, request_id, facility_id, starts_at, starts_at + interval '2 hours', 'booked', 'booked'
from check_in_window_test,
(values
  (
    '98100000-0000-0000-0000-000000000001'::uuid,
    '98000000-0000-0000-0000-000000000001'::uuid,
    now() - interval '20 minutes'
  ),
  (
    '98100000-0000-0000-0000-000000000002'::uuid,
    '98000000-0000-0000-0000-000000000002'::uuid,
    now() - interval '45 minutes'
  ),
  (
    '98100000-0000-0000-0000-000000000003'::uuid,
    '98000000-0000-0000-0000-000000000003'::uuid,
    now()
  ),
  (
    '98100000-0000-0000-0000-000000000004'::uuid,
    '98000000-0000-0000-0000-000000000004'::uuid,
    now() - interval '20 minutes'
  ),
  (
    '98100000-0000-0000-0000-000000000005'::uuid,
    '98000000-0000-0000-0000-000000000005'::uuid,
    now() - interval '35 minutes'
  )
) as rows(occurrence_id, request_id, starts_at);

select set_config(
  'request.jwt.claim.sub', (select requester_id::text from check_in_window_test), false
);

-- A check-in 20 minutes late succeeds and records the delay.
select lives_ok(
  $$select public.self_check_in_occurrence(
    '98000000-0000-0000-0000-000000000001', '98100000-0000-0000-0000-000000000001'
  )$$,
  'checking in 20 minutes late is still inside the 30-minute window'
);
select is(
  (select lifecycle_stage::text from public.reservation_occurrences
   where id = '98100000-0000-0000-0000-000000000001'),
  'checked_in', 'the occurrence is marked checked in'
);
select is(
  (select check_in_late_minutes from public.reservation_occurrences
   where id = '98100000-0000-0000-0000-000000000001'),
  20, 'the occurrence records 20 minutes late'
);
select is(
  (select details->>'late_minutes' from public.reservation_events
   where occurrence_id = '98100000-0000-0000-0000-000000000001'
     and action = 'self check in'),
  '20', 'the check-in event records the late minutes in its details'
);

-- A check-in attempted 45 minutes after start is outside the window.
select throws_ok(
  $$select public.self_check_in_occurrence(
    '98000000-0000-0000-0000-000000000002', '98100000-0000-0000-0000-000000000002'
  )$$,
  '22023', 'Check-in closed 30 minutes after the booking start',
  'check-in is rejected more than 30 minutes after the booking start'
);

-- An on-time check-in records zero late minutes and no late note.
select lives_ok(
  $$select public.self_check_in_occurrence(
    '98000000-0000-0000-0000-000000000003', '98100000-0000-0000-0000-000000000003'
  )$$,
  'checking in exactly on time succeeds'
);
select is(
  (select check_in_late_minutes from public.reservation_occurrences
   where id = '98100000-0000-0000-0000-000000000003'),
  0, 'an on-time check-in records zero late minutes'
);
select is(
  (select reason from public.reservation_events
   where occurrence_id = '98100000-0000-0000-0000-000000000003'
     and action = 'self check in'),
  null, 'an on-time check-in has no late note'
);

-- Admin no-show grace now matches the 30-minute check-in window.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from check_in_window_test), false
);

select throws_ok(
  $$select public.record_occurrence_attendance(
    '98000000-0000-0000-0000-000000000004', '98100000-0000-0000-0000-000000000004', 'no_show'
  )$$,
  '22023', 'The no-show grace period has not ended',
  'a no-show cannot be marked while self check-in is still open (20 minutes in)'
);

select lives_ok(
  $$select public.record_occurrence_attendance(
    '98000000-0000-0000-0000-000000000005', '98100000-0000-0000-0000-000000000005', 'no_show'
  )$$,
  'a no-show can be marked once the 30-minute grace has fully elapsed'
);

select * from finish();
rollback;
