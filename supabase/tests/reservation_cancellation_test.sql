begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(18);

create temp table cancellation_test as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) outsider_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, created_at
)
select '99000000-0000-0000-0000-000000000001', user_id, facility_id,
  'Cancellation Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Single cancellation', 10, 'pending', 'pending_approval', 'internal', now()
from cancellation_test
union all
select '99000000-0000-0000-0000-000000000002', user_id, facility_id,
  'Cancellation Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Series cancellation', 10, 'pending', 'pending_approval', 'internal', now()
from cancellation_test
union all
select '99000000-0000-0000-0000-000000000003', user_id, facility_id,
  'Cancellation Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Administrator cancellation', 10, 'pending', 'pending_approval', 'internal', now()
from cancellation_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state
)
select '99100000-0000-0000-0000-000000000001',
  '99000000-0000-0000-0000-000000000001', facility_id,
  now() + interval '2 days', now() + interval '2 days 1 hour', 'requested'
from cancellation_test
union all
select '99100000-0000-0000-0000-000000000002',
  '99000000-0000-0000-0000-000000000002', facility_id,
  now() + interval '3 days', now() + interval '3 days 1 hour', 'requested'
from cancellation_test
union all
select '99100000-0000-0000-0000-000000000003',
  '99000000-0000-0000-0000-000000000002', facility_id,
  now() + interval '4 days', now() + interval '4 days 1 hour', 'requested'
from cancellation_test
union all
select '99100000-0000-0000-0000-000000000004',
  '99000000-0000-0000-0000-000000000003', facility_id,
  now() + interval '5 days', now() + interval '5 days 1 hour', 'requested'
from cancellation_test;

select set_config(
  'request.jwt.claim.sub', (select user_id::text from cancellation_test), false
);

create temp table single_cancel_result as
select public.reservation_action(
  '99000000-0000-0000-0000-000000000001', 'cancel', null, '{}'::jsonb, 1,
  '99200000-0000-0000-0000-000000000001'
) result;

select isnt(result->>'action_id', null, 'payment-free cancellation is undoable')
from single_cancel_result;
select is((select booking_state from public.reservation_occurrences
  where id='99100000-0000-0000-0000-000000000001'), 'cancelled',
  'single future occurrence is cancelled');
select is((select status from public.reservation_requests
  where id='99000000-0000-0000-0000-000000000001'), 'cancelled',
  'single cancellation updates legacy status');
select is((select reservation_status from public.reservation_requests
  where id='99000000-0000-0000-0000-000000000001'), 'cancelled',
  'single cancellation updates authoritative lifecycle status');

select is(
  (public.reservation_action(
    '99000000-0000-0000-0000-000000000001','cancel',null,'{}'::jsonb,1,
    '99200000-0000-0000-0000-000000000001')->>'duplicate')::boolean,
  true, 'reusing a cancellation idempotency key returns the original action'
);
select is((select count(*) from public.reservation_events
  where request_id='99000000-0000-0000-0000-000000000001'
    and action='cancel'), 1::bigint,
  'an idempotent retry does not create another cancellation event');

select throws_ok(
  $$select public.reservation_action(
    '99000000-0000-0000-0000-000000000001','cancel',null,'{}'::jsonb,null,
    '99200000-0000-0000-0000-000000000002')$$,
  '22023', 'A terminal reservation cannot be cancelled',
  'a terminal reservation cannot be cancelled again'
);

select set_config(
  'request.jwt.claim.sub', (select outsider_id::text from cancellation_test), false
);
select lives_ok(
  $$select public.reservation_action(
    '99000000-0000-0000-0000-000000000003','cancel',null,'{}'::jsonb,1,
    '99200000-0000-0000-0000-000000000007')$$,
  'an assigned administrator can cancel an in-scope reservation'
);

update public.profiles set role = 'external_admin'
where id = (select outsider_id from cancellation_test);
select throws_ok(
  $$select public.reservation_action(
    '99000000-0000-0000-0000-000000000002','cancel',null,'{}'::jsonb,1,
    '99200000-0000-0000-0000-000000000003')$$,
  '42501', 'Reservation access denied',
  'an unassigned administrator cannot cancel another lane reservation'
);

select set_config(
  'request.jwt.claim.sub', (select user_id::text from cancellation_test), false
);
select public.reservation_action(
  '99000000-0000-0000-0000-000000000002', 'cancel', null,
  jsonb_build_object('occurrence_id','99100000-0000-0000-0000-000000000002'),
  1, '99200000-0000-0000-0000-000000000004'
);

select is((select booking_state from public.reservation_occurrences
  where id='99100000-0000-0000-0000-000000000002'), 'cancelled',
  'targeted series cancellation changes only the selected date');
select is((select booking_state from public.reservation_occurrences
  where id='99100000-0000-0000-0000-000000000003'), 'requested',
  'another future series date remains active');
select is((select status from public.reservation_requests
  where id='99000000-0000-0000-0000-000000000002'), 'pending',
  'partial series cancellation keeps the aggregate request active');

select throws_ok(
  $$select public.reservation_action(
    '99000000-0000-0000-0000-000000000002','cancel',null,
    jsonb_build_object('occurrence_id','99100000-0000-0000-0000-000000000002'),
    2,'99200000-0000-0000-0000-000000000008')$$,
  '22023', 'Only future reservations that have not started can be cancelled',
  'a zero-row targeted cancellation fails instead of reporting success'
);

select throws_ok(
  $$select public.reservation_action(
    '99000000-0000-0000-0000-000000000002','cancel',null,'{}'::jsonb,1,
    '99200000-0000-0000-0000-000000000005')$$,
  '40001', 'This reservation changed. Refresh and try again',
  'stale request versions are rejected'
);

create temp table series_cancel_result as
select public.reservation_action(
  '99000000-0000-0000-0000-000000000002', 'cancel', null, '{}'::jsonb, 2,
  '99200000-0000-0000-0000-000000000006'
) result;

select is((select status || '/' || reservation_status
  from public.reservation_requests
  where id='99000000-0000-0000-0000-000000000002'),
  'cancelled/cancelled', 'cancelling the final future date closes both statuses');

select lives_ok(
  $$select public.undo_reservation_action(
    (select (result->>'action_id')::uuid from series_cancel_result))$$,
  'the requester can undo their own payment-free cancellation'
);
select is((select booking_state from public.reservation_occurrences
  where id='99100000-0000-0000-0000-000000000003'), 'requested',
  'requester undo restores the final future occurrence');
select is((select status from public.reservation_requests
  where id='99000000-0000-0000-0000-000000000002'), 'pending',
  'requester undo restores the aggregate request state');

select * from finish();
rollback;
