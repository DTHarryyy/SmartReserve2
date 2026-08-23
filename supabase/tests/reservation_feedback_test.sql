begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(15);

create temp table feedback_test as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) internal_admin_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

-- A completed reservation (both request and occurrence reflect a genuine
-- check-in -> complete cycle) belonging to user_id.
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, created_at
)
select '98000000-0000-0000-0000-000000000001', user_id, facility_id,
  'Feedback Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Completed reservation', 10, 'approved', 'completed', 'internal', now()
from feedback_test
union all
-- Confirmed but not yet completed.
select '98000000-0000-0000-0000-000000000002', user_id, facility_id,
  'Feedback Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Confirmed reservation', 10, 'approved', 'confirmed', 'internal', now()
from feedback_test
union all
-- Completed but every occurrence is a no-show -- must NOT be feedback
-- eligible even though reservation_status = 'completed'.
select '98000000-0000-0000-0000-000000000003', user_id, facility_id,
  'Feedback Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'No-show series', 10, 'approved', 'completed', 'internal', now()
from feedback_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '98100000-0000-0000-0000-000000000001',
  '98000000-0000-0000-0000-000000000001', facility_id,
  now() - interval '2 days', now() - interval '2 days' + interval '1 hour',
  'booked', 'completed'
from feedback_test
union all
select '98100000-0000-0000-0000-000000000002',
  '98000000-0000-0000-0000-000000000002', facility_id,
  now() + interval '2 days', now() + interval '2 days' + interval '1 hour',
  'booked', 'booked'
from feedback_test
union all
select '98100000-0000-0000-0000-000000000003',
  '98000000-0000-0000-0000-000000000003', facility_id,
  now() - interval '3 days', now() - interval '3 days' + interval '1 hour',
  'booked', 'no_show'
from feedback_test;

-- Non-owner cannot submit feedback, even an administrator who could
-- otherwise manage the reservation.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from feedback_test), false
);
select throws_ok(
  $$select public.submit_reservation_feedback(
    '98000000-0000-0000-0000-000000000001', 5, 'Great room')$$,
  '42501', 'Feedback is limited to the person who booked',
  'a non-owner (even an admin) cannot submit feedback for someone else''s reservation'
);

select set_config(
  'request.jwt.claim.sub', (select user_id::text from feedback_test), false
);

-- Not completed yet.
select throws_ok(
  $$select public.submit_reservation_feedback(
    '98000000-0000-0000-0000-000000000002', 4, 'Nice')$$,
  '22023', 'Feedback opens once the reservation is completed',
  'a confirmed (not completed) reservation cannot receive feedback'
);

-- Completed but every occurrence was a no-show.
select throws_ok(
  $$select public.submit_reservation_feedback(
    '98000000-0000-0000-0000-000000000003', 3, 'n/a')$$,
  '22023', 'Feedback opens once the reservation is completed',
  'an all-no-show series cannot receive feedback despite reservation_status=completed'
);

-- Rating out of range.
select throws_ok(
  $$select public.submit_reservation_feedback(
    '98000000-0000-0000-0000-000000000001', 0, 'bad')$$,
  '22023', 'Choose a rating from 1 to 5',
  'rating 0 is rejected'
);
select throws_ok(
  $$select public.submit_reservation_feedback(
    '98000000-0000-0000-0000-000000000001', 6, 'bad')$$,
  '22023', 'Choose a rating from 1 to 5',
  'rating 6 is rejected'
);

-- Comment too long.
select throws_ok(
  format(
    $$select public.submit_reservation_feedback(
      '98000000-0000-0000-0000-000000000001', 4, %L)$$,
    repeat('x', 501)
  ),
  '22023', 'Keep your comment under 500 characters',
  'a 501-character comment is rejected'
);

-- A valid, low-rating submission succeeds and fans out an admin alert.
create temp table feedback_result as
select public.submit_reservation_feedback(
  '98000000-0000-0000-0000-000000000001', 2, 'The projector did not work'
) result;

select is((select (result).rating from feedback_result), 2::smallint,
  'the stored rating matches the submission');

select is(
  (select rating_average from public.facility_rating_stats
   where facility_id = (select facility_id from feedback_test)),
  2.00::numeric, 'facility_rating_stats.rating_average reflects the single review'
);
select is(
  (select rating_count from public.facility_rating_stats
   where facility_id = (select facility_id from feedback_test)),
  1, 'facility_rating_stats.rating_count reflects the single review'
);

select is(
  (select count(*)::int from public.app_notifications
   where kind = 'feedback_low_rating'
     and request_id = '98000000-0000-0000-0000-000000000001'
     and recipient_id = (select internal_admin_id from feedback_test)),
  1, 'a 2-star rating notifies the managing internal admin exactly once'
);

-- A second submission for the same reservation is rejected.
select throws_ok(
  $$select public.submit_reservation_feedback(
    '98000000-0000-0000-0000-000000000001', 5, 'again')$$,
  '23505', 'You already left feedback for this reservation',
  'a second submission for the same reservation is rejected'
);

-- The rating aggregate is exact after a second, different rating and after
-- a delete.
update public.reservation_requests
set reservation_status = 'completed', status = 'approved'
where id = '98000000-0000-0000-0000-000000000002';
update public.reservation_occurrences
set lifecycle_stage = 'completed'
where id = '98100000-0000-0000-0000-000000000002';

select public.submit_reservation_feedback(
  '98000000-0000-0000-0000-000000000002', 4, 'Solid, but AC was loud'
);

select is(
  (select rating_average from public.facility_rating_stats
   where facility_id = (select facility_id from feedback_test)),
  3.00::numeric, 'the average is exact across two reviews (2 and 4 -> 3.00)'
);

delete from public.reservation_feedback
where reservation_id = '98000000-0000-0000-0000-000000000001';

select is(
  (select rating_average from public.facility_rating_stats
   where facility_id = (select facility_id from feedback_test)),
  4.00::numeric, 'the average recomputes correctly after a delete'
);
select is(
  (select rating_count from public.facility_rating_stats
   where facility_id = (select facility_id from feedback_test)),
  1, 'the count recomputes correctly after a delete'
);

-- An admin with no assignment to this facility (demoted to external_admin
-- for the check, matching the house pattern in external_admin_scope_test.sql)
-- cannot read its feedback.
create temp table feedback_scope as
select internal_admin_id as outsider_id from feedback_test;
delete from public.facility_admin_assignments
where admin_id = (select outsider_id from feedback_scope)
  and facility_id = (select facility_id from feedback_test);
update public.profiles set role = 'external_admin'
where id = (select outsider_id from feedback_scope);
select set_config(
  'request.jwt.claim.sub', (select outsider_id::text from feedback_scope), false
);
select is(
  (select count(*)::int from public.reservation_feedback
   where reservation_id = '98000000-0000-0000-0000-000000000002'),
  0, 'an unassigned admin cannot select feedback for a facility outside their scope'
);

select * from finish();
rollback;
