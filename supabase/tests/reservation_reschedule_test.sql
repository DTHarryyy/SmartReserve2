begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(12);

create temp table reschedule_test as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) outsider_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id,
  ((date_trunc('day', now() at time zone 'Asia/Manila') + interval '2 days 10 hours')
    at time zone 'Asia/Manila') original_start,
  ((date_trunc('day', now() at time zone 'Asia/Manila') + interval '3 days 12 hours')
    at time zone 'Asia/Manila') new_start;

update public.facilities
set open_days = array[true, true, true, true, true, true, true],
    open_time = '00:00',
    close_time = '23:59',
    max_duration_minutes = 120,
    advance_booking_days = 365
where id = (select facility_id from reschedule_test);

delete from public.notification_preferences
where user_id = (select user_id from reschedule_test);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, created_at
)
select
  '99300000-0000-0000-0000-000000000001', user_id, facility_id,
  'Reschedule Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Requester move', 10, 'approved', 'confirmed', 'internal', now()
from reschedule_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state
)
select
  '99400000-0000-0000-0000-000000000001',
  '99300000-0000-0000-0000-000000000001', facility_id,
  original_start, original_start + interval '1 hour', 'booked'
from reschedule_test;

select set_config(
  'request.jwt.claim.sub', (select user_id::text from reschedule_test), false
);

select lives_ok(
  format(
    $$select public.request_reservation_reschedule(
      '99300000-0000-0000-0000-000000000001',
      '99400000-0000-0000-0000-000000000001',
      %L::timestamptz, %L::timestamptz, 'Class schedule changed', 1,
      '99500000-0000-0000-0000-000000000001')$$,
    (select new_start from reschedule_test),
    (select new_start + interval '90 minutes' from reschedule_test)
  ),
  'the requester can ask to move a future reservation'
);

select is(
  (select booking_state from public.reservation_occurrences
   where id = '99400000-0000-0000-0000-000000000001'),
  'requested',
  'the old confirmed hold becomes a requested replacement slot'
);
select is(
  (select starts_at from public.reservation_occurrences
   where id = '99400000-0000-0000-0000-000000000001'),
  (select new_start from reschedule_test),
  'the occurrence uses the requested start time'
);
select is(
  (select ends_at from public.reservation_occurrences
   where id = '99400000-0000-0000-0000-000000000001'),
  (select new_start + interval '90 minutes' from reschedule_test),
  'a payment-free reservation may choose a new end time'
);
select is(
  (select status || '/' || reservation_status
   from public.reservation_requests
   where id = '99300000-0000-0000-0000-000000000001'),
  'pending/pending_approval',
  'the moved schedule returns to admin approval'
);
select like(
  (select decision_reason from public.reservation_requests
   where id = '99300000-0000-0000-0000-000000000001'),
  '%Class schedule changed%',
  'the requester reason is visible to the administrator'
);
select is(
  (select count(*) from public.reservation_events
   where request_id = '99300000-0000-0000-0000-000000000001'
     and action = 'requested a reservation reschedule'),
  1::bigint,
  'the reschedule is recorded in reservation activity'
);
select ok(
  (select count(*) > 0 from public.app_notifications
   where request_id = '99300000-0000-0000-0000-000000000001'
     and kind = 'reservation_reschedule_requested'),
  'the responsible admin lane is notified'
);
select is(
  (select count(*) from public.app_notifications
   where request_id = '99300000-0000-0000-0000-000000000001'
     and kind = 'reservation_reschedule_sent'),
  1::bigint,
  'the requester receives a confirmation notification'
);
select is(
  (public.request_reservation_reschedule(
    '99300000-0000-0000-0000-000000000001',
    '99400000-0000-0000-0000-000000000001',
    (select new_start from reschedule_test),
    (select new_start + interval '90 minutes' from reschedule_test),
    'Class schedule changed', 2,
    '99500000-0000-0000-0000-000000000001'
  )->>'duplicate')::boolean,
  true,
  'an idempotent retry does not submit the move twice'
);

select throws_ok(
  format(
    $$select public.request_reservation_reschedule(
      '99300000-0000-0000-0000-000000000001',
      '99400000-0000-0000-0000-000000000001',
      %L::timestamptz, %L::timestamptz, 'Try a longer booking', 2,
      '99500000-0000-0000-0000-000000000003')$$,
    (select new_start + interval '1 day' from reschedule_test),
    (select new_start + interval '1 day 3 hours' from reschedule_test)
  ),
  '22023', 'Reservation exceeds the facility maximum duration',
  'a reschedule cannot exceed the facility maximum duration'
);

select set_config(
  'request.jwt.claim.sub', (select outsider_id::text from reschedule_test), false
);
select throws_ok(
  format(
    $$select public.request_reservation_reschedule(
      '99300000-0000-0000-0000-000000000001',
      '99400000-0000-0000-0000-000000000001',
      %L::timestamptz, %L::timestamptz, 'Try another move', 2,
      '99500000-0000-0000-0000-000000000002')$$,
    (select new_start + interval '1 day' from reschedule_test),
    (select new_start + interval '1 day 1 hour' from reschedule_test)
  ),
  '42501', 'Reservation access denied',
  'another account cannot move the requester reservation'
);

select * from finish();
rollback;
