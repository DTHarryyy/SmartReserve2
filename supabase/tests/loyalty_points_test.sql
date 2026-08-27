begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(48);

create temp table loyalty_test as
select
  (select id from public.profiles where email = 'user@csu.edu.ph') user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) internal_admin_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

delete from public.loyalty_redemptions
where user_id = (select user_id from loyalty_test);
delete from public.loyalty_transactions
where user_id = (select user_id from loyalty_test);
delete from public.loyalty_rewards
where name in (
  'Priority booking slot',
  'Sticker pack',
  'Pending renter voucher'
);

update public.profiles
set role = 'user',
    account_status = 'active',
    verification_status = 'none',
    campus_claim = 'none',
    unit = null
where id = (select user_id from loyalty_test);

select is(
  (select points from public.loyalty_point_rules where transaction_type = 'reservation_completed'),
  10, 'the seeded reservation_completed rule is 10 points'
);
select is(
  (select points from public.loyalty_point_rules where transaction_type = 'feedback_submitted'),
  5, 'the seeded feedback_submitted rule is 5 points'
);

select ok(
  public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'unverified guest-priced renters are loyalty eligible'
);
update public.profiles
set verification_status = 'pending', campus_claim = 'student', unit = 'BSIT'
where id = (select user_id from loyalty_test);
select ok(
  public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'pending campus claims remain guest-priced and loyalty eligible'
);
update public.profiles
set verification_status = 'verified', campus_claim = 'student', unit = 'BSIT'
where id = (select user_id from loyalty_test);
select ok(
  not public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'verified students are not loyalty eligible'
);
update public.profiles
set verification_status = 'verified', campus_claim = 'faculty', unit = 'College of Education'
where id = (select user_id from loyalty_test);
select ok(
  not public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'verified faculty are not loyalty eligible'
);
update public.profiles
set verification_status = 'verified', campus_claim = 'staff', unit = 'Legal Office'
where id = (select user_id from loyalty_test);
select ok(
  not public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'verified staff are not loyalty eligible'
);

update public.profiles
set verification_status = 'none', campus_claim = 'none', unit = null
where id = (select user_id from loyalty_test);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, version, created_at
)
select '97000000-0000-0000-0000-000000000001', user_id, facility_id,
  'Loyalty Guest', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Completion award test', 10, 'approved', 'confirmed', 'external', 'guest', 1, now()
from loyalty_test
union all
select '97000000-0000-0000-0000-000000000002', user_id, facility_id,
  'Loyalty Guest', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'No-show award test', 10, 'approved', 'confirmed', 'external', 'guest', 1, now()
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
  'completed', 'the guest reservation reached completed through the real RPC path'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'reservation_completed'
     and source_type = 'reservation'
     and source_id = '97000000-0000-0000-0000-000000000001'),
  1, 'guest-priced completion awards exactly one ledger row'
);
select is(
  (select points from public.loyalty_transactions
   where transaction_type = 'reservation_completed'
     and source_id = '97000000-0000-0000-0000-000000000001'),
  10, 'the guest completion award matches the configured rule'
);

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

select public.reservation_action(
  '97000000-0000-0000-0000-000000000001', 'complete', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000001'), 4
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000001'),
  1, 'undo then re-complete still yields exactly one award'
);

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000001', 5, 'Perfect'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'feedback_submitted'
     and source_type = 'feedback'),
  1, 'guest-priced feedback awards exactly one ledger row'
);
select is(
  public.loyalty_balance((select user_id from loyalty_test)),
  15, 'the guest balance is the completion and feedback awards'
);

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
    $$select public.redeem_loyalty_reward(%L::uuid)$$,
    (select id::text from reward_ref)
  ),
  '22023', null,
  'redeeming an unaffordable reward is rejected'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)
     and transaction_type = 'reward_redeemed'),
  0, 'a rejected redemption leaves the ledger untouched'
);

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
  5, 'the guest balance reflects the redemption'
);
select is(
  (select count(*)::int from public.loyalty_redemptions
   where user_id = (select user_id from loyalty_test)),
  1, 'the guest redemption creates exactly one redemption record'
);

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.set_loyalty_reward_active((select id from cheap_reward), false);
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select throws_ok(
  format($$select public.redeem_loyalty_reward(%L::uuid)$$, (select id::text from cheap_reward)),
  '22023', 'This reward is not available',
  'an inactive reward cannot be redeemed'
);

select throws_ok(
  format(
    $$select public.adjust_loyalty_points(%L::uuid, 50, 'not an admin')$$,
    (select user_id::text from loyalty_test)
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
  55, 'an admin adjustment is reflected in an eligible guest balance'
);
select is(
  (select count(*)::int from public.audit_entries
   where source_type = 'loyalty_adjustment'
     and entity_id = (select user_id from loyalty_test)),
  1, 'an admin adjustment writes exactly one audit_entries row'
);

update public.profiles
set verification_status = 'pending', campus_claim = 'student', unit = 'BSIT'
where id = (select user_id from loyalty_test);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, version, created_at
)
select '97000000-0000-0000-0000-000000000003', user_id, facility_id,
  'Loyalty Pending', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Pending renter award test', 10, 'approved', 'confirmed', 'external', 'guest', 1, now()
from loyalty_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '97100000-0000-0000-0000-000000000003',
  '97000000-0000-0000-0000-000000000003', facility_id,
  now() - interval '2 hours', now() - interval '1 hour', 'booked', 'booked'
from loyalty_test;

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.reservation_action(
  '97000000-0000-0000-0000-000000000003', 'check_in', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000003'), 1
);
select public.reservation_action(
  '97000000-0000-0000-0000-000000000003', 'complete', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000003'), 2
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000003'),
  1, 'pending guest-priced completion awards points'
);

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000003', 5, 'Still paying guest rate'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'feedback_submitted'),
  2, 'pending guest-priced feedback awards points'
);

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select public.save_loyalty_reward(
  null, 'Pending renter voucher', 'Guest-rate renter voucher', 5, true, null
);
create temp table pending_reward as
select id from public.loyalty_rewards where name = 'Pending renter voucher';

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.redeem_loyalty_reward((select id from pending_reward));
select is(
  public.loyalty_balance((select user_id from loyalty_test)),
  65, 'pending guest-priced renters can redeem normally'
);

update public.profiles
set verification_status = 'verified', campus_claim = 'student', unit = 'BSIT'
where id = (select user_id from loyalty_test);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, created_at
)
select '97000000-0000-0000-0000-000000000004', user_id, facility_id,
  'Verified Student', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Student award block test', 10, 'approved', 'confirmed', 'internal', 'student', now()
from loyalty_test;
insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '97100000-0000-0000-0000-000000000004',
  '97000000-0000-0000-0000-000000000004', facility_id,
  now() - interval '2 hours', now() - interval '1 hour', 'booked', 'completed'
from loyalty_test;
update public.reservation_requests
set reservation_status = 'completed'
where id = '97000000-0000-0000-0000-000000000004';
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000004'),
  0, 'verified student-priced completion awards no points'
);
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000004', 4, 'Campus-priced reservation'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'feedback_submitted'),
  2, 'verified student-priced feedback awards no points'
);

update public.profiles
set verification_status = 'verified', campus_claim = 'faculty', unit = 'College of Education'
where id = (select user_id from loyalty_test);
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, created_at
)
select '97000000-0000-0000-0000-000000000005', user_id, facility_id,
  'Verified Faculty', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Faculty award block test', 10, 'approved', 'confirmed', 'internal', 'faculty', now()
from loyalty_test;
insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '97100000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000005', facility_id,
  now() - interval '2 hours', now() - interval '1 hour', 'booked', 'completed'
from loyalty_test;
update public.reservation_requests
set reservation_status = 'completed'
where id = '97000000-0000-0000-0000-000000000005';
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000005', 4, 'Faculty campus pricing'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000005'),
  0, 'verified faculty-priced completion awards no points'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'feedback_submitted'),
  2, 'verified faculty-priced feedback awards no points'
);

update public.profiles
set verification_status = 'verified', campus_claim = 'staff', unit = 'Legal Office'
where id = (select user_id from loyalty_test);
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, created_at
)
select '97000000-0000-0000-0000-000000000006', user_id, facility_id,
  'Verified Staff', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Staff award block test', 10, 'approved', 'confirmed', 'internal', 'staff', now()
from loyalty_test;
insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '97100000-0000-0000-0000-000000000006',
  '97000000-0000-0000-0000-000000000006', facility_id,
  now() - interval '2 hours', now() - interval '1 hour', 'booked', 'completed'
from loyalty_test;
update public.reservation_requests
set reservation_status = 'completed'
where id = '97000000-0000-0000-0000-000000000006';
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000006', 4, 'Staff campus pricing'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97000000-0000-0000-0000-000000000006'),
  0, 'verified staff-priced completion awards no points'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where transaction_type = 'feedback_submitted'),
  2, 'verified staff-priced feedback awards no points'
);

select is(
  (public.loyalty_my_summary()->>'eligible')::boolean,
  false, 'verified renters receive an ineligible loyalty summary'
);
select is(
  jsonb_array_length(public.loyalty_my_summary()->'transactions'),
  0, 'verified renters receive no loyalty transaction payload'
);
select is(
  jsonb_array_length(public.loyalty_my_summary()->'rewards'),
  0, 'verified renters receive no loyalty reward payload'
);
select is(
  public.loyalty_balance((select user_id from loyalty_test)),
  0, 'verified renters cannot use their retained balance'
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)),
  0, 'direct RLS hides retained ledger rows from verified renters'
);
select throws_ok(
  format($$select public.redeem_loyalty_reward(%L::uuid)$$, (select id::text from pending_reward)),
  '42501', 'Loyalty rewards are available to guest renters only',
  'verified renters cannot redeem retained points'
);

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select throws_ok(
  format(
    $$select public.adjust_loyalty_points(%L::uuid, 5, 'verified user')$$,
    (select user_id::text from loyalty_test)
  ),
  '42501', 'Loyalty adjustments are limited to guest renters',
  'admins cannot manually adjust verified renter loyalty'
);
select is(
  (select count(*)::int
   from public.loyalty_admin_balances('', 100)
   where user_id = (select user_id from loyalty_test)),
  0, 'admin balance lists exclude verified renters'
);
select ok(
  (select count(*)::int
   from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)) > 0,
  'internal admins can still audit retained ledger rows'
);

update public.profiles
set verification_status = 'none', campus_claim = 'none', unit = null
where id = (select user_id from loyalty_test);
select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select ok(
  public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'the same account becomes eligible again when it returns to guest pricing'
);
select is(
  (public.loyalty_my_summary()->>'eligible')::boolean,
  true, 'guest-priced renters receive an eligible loyalty summary again'
);
select is(
  (public.loyalty_my_summary()->>'balance')::int,
  65, 'the retained guest-earned balance becomes available again'
);
select is(
  jsonb_array_length(public.loyalty_my_summary()->'redemptions'),
  2, 'guest-priced renters can see their retained redemptions again'
);

select throws_ok(
  format(
    $$insert into public.loyalty_transactions(
        user_id, points, transaction_type, source_type, source_id
      ) values (%L::uuid, 999, 'admin_adjustment', 'admin', gen_random_uuid())$$,
    (select user_id::text from loyalty_test)
  ),
  '42501', null,
  'a direct insert into loyalty_transactions is rejected'
);

select * from finish();
rollback;
