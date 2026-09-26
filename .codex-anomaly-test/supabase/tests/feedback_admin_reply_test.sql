-- Admin replies to renter feedback (20260924090000_feedback_admin_replies.sql).
--
-- Covers: the write is lane-scoped via can_manage_reservation() even though
-- read access to reservation_feedback (and now its reply) stays global for
-- both admin lanes; the RPC upserts in place (one reply per review, no
-- duplicate rows, revision increments); the app_notifications row is
-- repeat-safe and comes back unread on an edit; and the 13-arg
-- feedback_admin_list() overload -- not the dead 9-arg one -- is the one
-- carrying the reply/lane projection.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(26);

create temp table far_ids as
select
  '9f000000-0000-0000-0000-000000000001'::uuid as internal_admin_id,
  '9f000000-0000-0000-0000-000000000002'::uuid as external_admin_id,
  '9f000000-0000-0000-0000-000000000003'::uuid as renter_id,
  '9f000000-0000-0000-0000-000000000004'::uuid as outsider_id,
  -- A dedicated facility, not the shared baseline one: on the live project
  -- the baseline facility carries real bookings, and this suite's synthetic
  -- occurrence windows collided with reservation_occurrences_no_overlap.
  '9f100000-0000-0000-0000-000000000001'::uuid as facility_id,
  '9f200000-0000-0000-0000-000000000001'::uuid as internal_request_id,
  '9f200000-0000-0000-0000-000000000002'::uuid as external_request_id;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select
  '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  email, 'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', full_name), now(), now(), '', '', '', ''
from (values
  ('9f000000-0000-0000-0000-000000000001'::uuid, 'far-internal-admin@example.test', 'FAR Internal Admin'),
  ('9f000000-0000-0000-0000-000000000002'::uuid, 'far-external-admin@example.test', 'FAR External Admin'),
  ('9f000000-0000-0000-0000-000000000003'::uuid, 'far-renter@example.test', 'FAR Renter'),
  ('9f000000-0000-0000-0000-000000000004'::uuid, 'far-outsider@example.test', 'FAR Outsider')
) as u(id, email, full_name)
on conflict (id) do update
set email = excluded.email,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete, created_at
)
values
  ('9f000000-0000-0000-0000-000000000001', 'far-internal-admin@example.test',
   'FAR Internal Admin', 'none', null, null, 'internal_admin', 'active', 'none', true, now()),
  ('9f000000-0000-0000-0000-000000000002', 'far-external-admin@example.test',
   'FAR External Admin', 'none', null, null, 'external_admin', 'active', 'none', true, now()),
  ('9f000000-0000-0000-0000-000000000003', 'far-renter@example.test',
   'FAR Renter', 'none', null, null, 'user', 'active', 'none', true, now()),
  ('9f000000-0000-0000-0000-000000000004', 'far-outsider@example.test',
   'FAR Outsider', 'none', null, null, 'user', 'active', 'none', true, now())
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    account_status = excluded.account_status,
    verification_status = excluded.verification_status,
    onboarding_complete = excluded.onboarding_complete,
    updated_at = now();

insert into public.facilities (
  id, name, building, category, capacity, status, public_listing,
  facility_classification, open_days, open_time, close_time, updated_by_name,
  amenities
)
select facility_id, 'FAR Test Room', 'FAR Building', 'Conference Room', 40,
  'active', false, 'shared',
  array[true,true,true,true,true,true,true], '00:00', '23:59', 'Test',
  array['Wi-Fi']
from far_ids
on conflict (id) do update
set status = excluded.status,
    public_listing = excluded.public_listing,
    facility_classification = excluded.facility_classification,
    updated_at = now();

-- Two completed reservations belonging to the renter, one in each lane, so
-- the same-lane/cross-lane gate on reply_to_feedback has something to bite.
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, created_at
)
select internal_request_id, renter_id, facility_id,
  'FAR Renter', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Internal-lane reservation', 10, 'approved', 'completed', 'internal', now()
from far_ids
union all
select external_request_id, renter_id, facility_id,
  'FAR Renter', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'External-lane reservation', 10, 'approved', 'completed', 'external', now()
from far_ids;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '9f210000-0000-0000-0000-000000000001'::uuid, internal_request_id, facility_id,
  now() - interval '2 days', now() - interval '2 days' + interval '1 hour',
  'booked', 'completed'
from far_ids
union all
select '9f210000-0000-0000-0000-000000000002'::uuid, external_request_id, facility_id,
  now() - interval '4 days', now() - interval '4 days' + interval '1 hour',
  'booked', 'completed'
from far_ids;

-- reply_to_feedback() and feedback_admin_list() exist with the expected
-- signatures and grants.
select has_function('public', 'reply_to_feedback', array['uuid', 'text'],
  'reply_to_feedback(uuid, text) exists');
select ok(
  has_function_privilege('authenticated', 'public.reply_to_feedback(uuid, text)', 'execute'),
  'authenticated can execute reply_to_feedback'
);
select ok(
  not has_function_privilege('anon', 'public.reply_to_feedback(uuid, text)', 'execute'),
  'anon cannot execute reply_to_feedback'
);
select has_function('public', 'feedback_admin_list', array[
    'text', 'uuid', 'integer', 'integer', 'timestamptz', 'timestamptz', 'text',
    'integer', 'integer', 'text', 'text', 'text', 'boolean'
  ],
  'the LIVE 13-arg feedback_admin_list overload -- not the dead 9-arg one -- was replaced'
);

-- The table grants only SELECT -- every write goes through the RPC.
select ok(
  has_table_privilege('authenticated', 'public.reservation_feedback_replies', 'SELECT'),
  'authenticated can select reservation_feedback_replies'
);
select ok(
  not has_table_privilege('authenticated', 'public.reservation_feedback_replies', 'INSERT'),
  'authenticated cannot insert reservation_feedback_replies directly'
);
select ok(
  not has_table_privilege('authenticated', 'public.reservation_feedback_replies', 'UPDATE'),
  'authenticated cannot update reservation_feedback_replies directly'
);

-- The renter leaves feedback on both reservations, via the RPC exactly as
-- the app does, so the eligibility checks that RPC enforces are exercised
-- rather than bypassed.
select set_config(
  'request.jwt.claim.sub', (select renter_id::text from far_ids), false
);
select public.submit_reservation_feedback(
  (select internal_request_id from far_ids), 3, 'It was fine.');
select public.submit_reservation_feedback(
  (select external_request_id from far_ids), 4, 'Also fine.');

create temp table far_feedback as
select
  (select id from public.reservation_feedback
   where reservation_id = (select internal_request_id from far_ids)) as internal_feedback_id,
  (select id from public.reservation_feedback
   where reservation_id = (select external_request_id from far_ids)) as external_feedback_id;

-- The RLS assertions below run `set local role authenticated`, which is not
-- the role that created these temp tables -- grant it access explicitly.
grant select on far_ids, far_feedback to authenticated;

-- A plain user (not an admin at all) cannot reply.
select throws_ok(
  $$select public.reply_to_feedback(
    (select internal_feedback_id from far_feedback), 'Thanks for the review!')$$,
  '42501', 'Administrator access required',
  'a plain user cannot reply to feedback'
);

-- Cross-lane: the external admin cannot reply on the internal-lane review.
select set_config(
  'request.jwt.claim.sub', (select external_admin_id::text from far_ids), false
);
select throws_ok(
  $$select public.reply_to_feedback(
    (select internal_feedback_id from far_feedback), 'Thanks for the review!')$$,
  '42501', 'This reservation belongs to another administrator lane',
  'an external admin cannot reply to a review on an internal-lane reservation'
);

-- A too-short message is rejected before anything is written.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from far_ids), false
);
select throws_ok(
  $$select public.reply_to_feedback((select internal_feedback_id from far_feedback), 'hi')$$,
  '22023', 'Reply must be between 3 and 1000 characters',
  'a too-short reply is rejected'
);

-- Same-lane: the internal admin can reply to the internal-lane review.
select lives_ok(
  $$select public.reply_to_feedback(
    (select internal_feedback_id from far_feedback), 'Thanks for the feedback, we fixed the AC.')$$,
  'a same-lane admin can reply'
);
select is(
  (select count(*)::int from public.reservation_feedback_replies
   where feedback_id = (select internal_feedback_id from far_feedback)),
  1, 'exactly one reply row exists after the first reply'
);
select is(
  (select revision from public.reservation_feedback_replies
   where feedback_id = (select internal_feedback_id from far_feedback)),
  1, 'the first reply is revision 1'
);
select is(
  (select count(*)::int from public.app_notifications
   where recipient_id = (select renter_id from far_ids)
     and request_id = (select internal_request_id from far_ids)
     and kind = 'feedback_reply'),
  1, 'exactly one feedback_reply notification exists after the first reply'
);
select is(
  (select read_at from public.app_notifications
   where recipient_id = (select renter_id from far_ids)
     and request_id = (select internal_request_id from far_ids)
     and kind = 'feedback_reply'),
  null::timestamptz, 'the notification starts unread'
);

-- The renter reads the notification...
select set_config(
  'request.jwt.claim.sub', (select renter_id::text from far_ids), false
);
select public.mark_my_notification_read((
  select id from public.app_notifications
  where recipient_id = (select renter_id from far_ids)
    and request_id = (select internal_request_id from far_ids)
    and kind = 'feedback_reply'
));

-- ...then the admin corrects the reply: same row, revision bumps, and the
-- notification comes back unread rather than a second row being created.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from far_ids), false
);
select lives_ok(
  $$select public.reply_to_feedback(
    (select internal_feedback_id from far_feedback), 'Correction: it was the vending machine, not the AC.')$$,
  'the same admin can edit their reply'
);
select is(
  (select count(*)::int from public.reservation_feedback_replies
   where feedback_id = (select internal_feedback_id from far_feedback)),
  1, 'editing the reply does not create a second row'
);
select is(
  (select revision from public.reservation_feedback_replies
   where feedback_id = (select internal_feedback_id from far_feedback)),
  2, 'editing the reply bumps the revision to 2'
);
select is(
  (select count(*)::int from public.app_notifications
   where recipient_id = (select renter_id from far_ids)
     and request_id = (select internal_request_id from far_ids)
     and kind = 'feedback_reply'),
  1, 'editing the reply still leaves exactly one notification row'
);
select is(
  (select read_at from public.app_notifications
   where recipient_id = (select renter_id from far_ids)
     and request_id = (select internal_request_id from far_ids)
     and kind = 'feedback_reply'),
  null::timestamptz, 'editing the reply resets the notification to unread'
);

-- RLS: the renter (recipient) can read their own reply.
select set_config(
  'request.jwt.claim.sub', (select renter_id::text from far_ids), false
);
set local role authenticated;
select ok(
  exists(select 1 from public.reservation_feedback_replies
    where feedback_id = (select internal_feedback_id from far_feedback)),
  'the recipient can select their own reply'
);
reset role;

-- RLS: an unrelated user cannot read it.
select set_config(
  'request.jwt.claim.sub', (select outsider_id::text from far_ids), false
);
set local role authenticated;
select ok(
  not exists(select 1 from public.reservation_feedback_replies
    where feedback_id = (select internal_feedback_id from far_feedback)),
  'an unrelated user cannot select the reply'
);
reset role;

-- RLS: global read access -- an external admin can still read a reply on an
-- internal-lane review, matching the pre-existing global feedback-read
-- policy. Only the WRITE is lane-scoped.
select set_config(
  'request.jwt.claim.sub', (select external_admin_id::text from far_ids), false
);
set local role authenticated;
select ok(
  exists(select 1 from public.reservation_feedback_replies
    where feedback_id = (select internal_feedback_id from far_feedback)),
  'an external admin can read a reply on an internal-lane review (read stays global)'
);
reset role;

-- feedback_admin_list() carries the reply and the reservation''s admin_lane,
-- which is what the client uses to gate the reply composer.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from far_ids), false
);
select is(
  (select (row->>'reply_message')
   from jsonb_array_elements(
     public.feedback_admin_list(p_facility_id => (select facility_id from far_ids))->'rows'
   ) row
   where (row->>'id')::uuid = (select internal_feedback_id from far_feedback)),
  'Correction: it was the vending machine, not the AC.',
  'feedback_admin_list projects the reply message'
);
select is(
  (select (row->>'reservation_admin_lane')
   from jsonb_array_elements(
     public.feedback_admin_list(p_facility_id => (select facility_id from far_ids))->'rows'
   ) row
   where (row->>'id')::uuid = (select internal_feedback_id from far_feedback)),
  'internal',
  'feedback_admin_list projects the reservation admin_lane'
);
select is(
  (select (row->>'reply_message')
   from jsonb_array_elements(
     public.feedback_admin_list(p_facility_id => (select facility_id from far_ids))->'rows'
   ) row
   where (row->>'id')::uuid = (select external_feedback_id from far_feedback)),
  null,
  'a review with no reply projects a null reply_message'
);

select * from finish();
rollback;
