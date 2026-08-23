begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(22);

create temp table loyalty_test as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) internal_admin_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

select is(
  (select points from public.loyalty_point_rules where transaction_type = 'reservation_completed'),
  10, 'the seeded reservation_completed rule is 10 points'
);
select is(
  (select points from public.loyalty_point_rules where transaction_type = 'feedback_submitted'),
  5, 'the seeded feedback_submitted rule is 5 points'
);

-- A pending -> confirmed reservation, ready to be driven through
-- check-in -> complete via the real reservation_action RPC.
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, version, created_at
)
select '97000000-0000-0000-0000-000000000001', user_id, facility_id,
  'Loyalty Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Completion award test', 10, 'approved', 'confirmed', 'internal', 1, now()
from loyalty_test
union all
-- An all-no-show series (never checked in) -- must award nothing.
select '97000000-0000-0000-0000-000000000002', user_id, facility_id,
  'Loyalty Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'No-show award test', 10, 'approved', 'confirmed', 'internal', 1, now()
from loyalty_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '97100000-0000-0000-0000-000000000001',
  '97000000-0000-0000-0000-000000000001', facility_id,
  now() - interval '2 hours', now() - interval '1 hour', 'booked', 'booked'
from loyalty_test
union all
select '97100000-0000-0000-0000-000000000002',
  '97000000-0000-0000-0000-000000000002', facility_id,
  now() - interval '2 hours', now() - interval '1 hour', 'booked', 'booked'
from loyalty_test;

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);

-- Drive the first reservation through the real check-in -> complete path.
select public.reservation_action(
  '97000000-0000-0000-0000-000000000001', 'check_in', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000001'), 1
);
select public.reservation_action(
  '97000000-0000-0000-0000-000000000001', 'complete', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000001'), 2
);

select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000001'),
  'completed', 'the reservation reached completed through the real RPC path'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'reservation_completed'
     and source_type = 'reservation'
     and source_id = '97000000-0000-0000-0000-000000000001'),
  1, 'completing the reservation awards exactly one ledger row'
);
select is(
  (select points from public.loyalty_transactions
   where transaction_type = 'reservation_completed'
     and source_id = '97000000-0000-0000-0000-000000000001'),
  10, 'the award matches the configured rule'
);

-- Mark the second (all-no-show) reservation no-show and confirm it
-- transitions to completed but awards nothing.
select public.reservation_action(
  '97000000-0000-0000-0000-000000000002', 'no_show', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000002'), 1
);
select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000002'),
  'completed', 'an all-no-show series still reaches completed'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000002'),
  0, 'an all-no-show completion awards nothing'
);

-- Undo the completion, then re-complete: still exactly one award. This is
-- the headline idempotency guarantee for the trigger design.
create temp table undo_target as
select id from public.reservation_action_journal
where request_ids @> array['97000000-0000-0000-0000-000000000001']::uuid[]
  and action = 'complete'
order by created_at desc limit 1;

select public.undo_reservation_action((select id from undo_target));
select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000001'),
  'confirmed', 'undo restores the reservation to confirmed'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000001'),
  1, 'undoing a completion does not claw back the award'
);

-- The undo restored the occurrence's pre-complete snapshot, which already
-- has lifecycle_stage = 'checked_in' (check-in was a separate, earlier
-- call) -- so completing again needs no repeat check-in. The undo's own
-- restore UPDATE bumped the request version from 3 to 4.
select public.reservation_action(
  '97000000-0000-0000-0000-000000000001', 'complete', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000001'), 4
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000001'),
  1, 'undo then re-complete still yields exactly one award (idempotency index holds)'
);

-- Feedback awards points too, keyed on the feedback id, and does not
-- duplicate on a repeated identical call.
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000001', 5, 'Perfect'
);
select is(
  (select count(*)::int from public.loyalty_transactions where transaction_type = 'feedback_submitted'),
  1, 'submitting feedback awards exactly one ledger row'
);
select is(
  public.loyalty_balance((select user_id from loyalty_test)),
  15, 'the balance is the sum of the completion and feedback awards (10 + 5)'
);

-- Redemption: insufficient balance is rejected and leaves the ledger
-- untouched.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.save_loyalty_reward(
  null, 'Priority booking slot', 'Skip the queue once', 1000, true, null
);
create temp table reward_ref as
select id from public.loyalty_rewards where name = 'Priority booking slot';

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select throws_ok(
  format(
    $$select public.redeem_loyalty_reward('%s')$$,
    (select id from reward_ref)
  ),
  '22023', null,
  'redeeming an unaffordable reward is rejected'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test) and transaction_type = 'reward_redeemed'),
  0, 'a rejected redemption leaves the ledger untouched'
);

-- An affordable, active reward redeems atomically: one redemption row, one
-- negative ledger row, balance drops accordingly.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.save_loyalty_reward(
  null, 'Sticker pack', 'A small campus sticker pack', 10, true, null
);
create temp table cheap_reward as
select id from public.loyalty_rewards where name = 'Sticker pack';

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.redeem_loyalty_reward((select id from cheap_reward));
select is(
  public.loyalty_balance((select user_id from loyalty_test)),
  5, 'the balance reflects the redemption (15 - 10 = 5)'
);
select is(
  (select count(*)::int from public.loyalty_redemptions
   where user_id = (select user_id from loyalty_test)),
  1, 'exactly one redemption record was created'
);

-- Redeeming an inactive reward is rejected.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.set_loyalty_reward_active((select id from cheap_reward), false);
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select throws_ok(
  format($$select public.redeem_loyalty_reward('%s')$$, (select id from cheap_reward)),
  '22023', 'This reward is not available',
  'an inactive reward cannot be redeemed'
);

-- Admin adjustments: guarded, ledgered, and audited.
select throws_ok(
  format(
    $$select public.adjust_loyalty_points('%s', 50, 'not an admin')$$,
    (select user_id from loyalty_test)
  ),
  '42501', 'Internal administrator access required',
  'a non-internal-admin cannot adjust points'
);

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.adjust_loyalty_points(
  (select user_id from loyalty_test), 50, 'University event participation'
);
select is(
  public.loyalty_balance((select user_id from loyalty_test)),
  55, 'an admin adjustment is reflected in the balance (5 + 50 = 55)'
);
select is(
  (select count(*)::int from public.audit_entries
   where source_type = 'loyalty_adjustment'
     and entity_id = (select user_id from loyalty_test)),
  1, 'an admin adjustment writes exactly one audit_entries row'
);

-- A user cannot select another user's ledger, and cannot write directly.
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where user_id <> (select user_id from loyalty_test)),
  0, 'a user cannot select another user''s loyalty ledger rows'
);
select throws_ok(
  format(
    $$insert into public.loyalty_transactions(
        user_id, points, transaction_type, source_type, source_id
      ) values ('%s', 999, 'admin_adjustment', 'admin', gen_random_uuid())$$,
    (select user_id from loyalty_test)
  ),
  '42501', null,
  'a direct insert into loyalty_transactions is rejected (no insert grant/policy)'
);

select * from finish();
rollback;
