begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(36);

create temp table loyalty_test as
select
  (select id from public.profiles where email = 'user@csu.edu.ph') user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) internal_admin_id,
  (select id from public.profiles where role = 'external_admin' order by created_at limit 1) external_admin_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

delete from public.loyalty_discount_applications
where claim_id in (
  select id from public.loyalty_discount_claims
  where offer_name like 'PgTAP loyalty%'
);
delete from public.loyalty_discount_claims
where offer_name like 'PgTAP loyalty%';
delete from public.loyalty_discount_offers
where name like 'PgTAP loyalty%';
delete from public.reservation_requests
where id in (
  '97000000-0000-0000-0000-000000000001',
  '97000000-0000-0000-0000-000000000002',
  '97000000-0000-0000-0000-000000000003',
  '97000000-0000-0000-0000-000000000004'
);
delete from public.loyalty_transactions
where user_id = (select user_id from loyalty_test);

update public.profiles
set role = 'user',
    account_status = 'active',
    verification_status = 'none',
    campus_claim = 'none',
    unit = null
where id = (select user_id from loyalty_test);

select is(
  (select points::text from public.loyalty_point_rules where transaction_type = 'booking_completed'),
  '1.0', 'completed bookings earn 1 point'
);
select is(
  (select points::text from public.loyalty_point_rules where transaction_type = 'booking_duration_1_to_4_hours'),
  '0.5', '1-4 hour bookings earn 0.5 duration points'
);
select is(
  (select points::text from public.loyalty_point_rules where transaction_type = 'booking_duration_5_plus_hours'),
  '1.0', '5+ hour bookings earn 1 capped duration point'
);
select is(
  (select points::text from public.loyalty_point_rules where transaction_type = 'booking_with_amenity'),
  '0.5', 'bookings with amenities earn 0.5 points'
);
select is(
  (select points::text from public.loyalty_point_rules where transaction_type = 'feedback_submitted'),
  '1.0', 'feedback earns 1 point'
);

select ok(
  public.loyalty_user_is_eligible((select user_id from loyalty_test)),
  'guest-priced renters are loyalty eligible'
);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, version, created_at
)
select id, user_id, facility_id, 'Loyalty Guest', 'user',
  'Computer Laboratory 1', 'CICS', 40, purpose, 10,
  'approved', 'confirmed', 'external', 'guest', 1, now()
from loyalty_test,
(values
  ('97000000-0000-0000-0000-000000000001'::uuid, 'Under one hour loyalty test'),
  ('97000000-0000-0000-0000-000000000002'::uuid, 'Two hour amenity loyalty test'),
  ('97000000-0000-0000-0000-000000000003'::uuid, 'Six hour loyalty test'),
  ('97000000-0000-0000-0000-000000000004'::uuid, 'No show loyalty test')
) as rows(id, purpose);

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select occurrence_id, request_id, facility_id, starts_at, ends_at, 'booked', 'booked'
from loyalty_test,
(values
  (
    '97100000-0000-0000-0000-000000000001'::uuid,
    '97000000-0000-0000-0000-000000000001'::uuid,
    now() - interval '90 minutes',
    now() - interval '60 minutes'
  ),
  (
    '97100000-0000-0000-0000-000000000002'::uuid,
    '97000000-0000-0000-0000-000000000002'::uuid,
    now() - interval '3 hours',
    now() - interval '1 hour'
  ),
  (
    '97100000-0000-0000-0000-000000000003'::uuid,
    '97000000-0000-0000-0000-000000000003'::uuid,
    now() - interval '8 hours',
    now() - interval '2 hours'
  ),
  (
    '97100000-0000-0000-0000-000000000004'::uuid,
    '97000000-0000-0000-0000-000000000004'::uuid,
    now() - interval '3 hours',
    now() - interval '1 hour'
  )
) as rows(occurrence_id, request_id, starts_at, ends_at);

insert into public.reservation_amenities(
  request_id, name_snapshot, unit_price_centavos, quantity, line_total_centavos
) values (
  '97000000-0000-0000-0000-000000000002',
  'Borrowed projector', 0, 1, 0
);

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
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where source_id = '97100000-0000-0000-0000-000000000001'),
  '1.0', 'durations below one hour only earn the completed-booking point'
);

select public.reservation_action(
  '97000000-0000-0000-0000-000000000002', 'check_in', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000002'), 1
);
select public.reservation_action(
  '97000000-0000-0000-0000-000000000002', 'complete', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000002'), 2
);
select is(
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where source_id = '97100000-0000-0000-0000-000000000002'),
  '2.0', 'a 1-4 hour amenity booking earns 2.0 total points'
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
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where source_id = '97100000-0000-0000-0000-000000000003'),
  '2.0', 'a 5+ hour booking earns the capped duration tier'
);

select public.reservation_action(
  '97000000-0000-0000-0000-000000000004', 'no_show', null,
  jsonb_build_object('occurrence_id', '97100000-0000-0000-0000-000000000004'), 1
);
select is(
  (select count(*)::int from public.loyalty_transactions
   where source_id = '97100000-0000-0000-0000-000000000004'),
  0, 'no-shows earn no booking, duration, or amenity points'
);

select public.correct_occurrence_attendance(
  '97100000-0000-0000-0000-000000000002', 'no_show',
  'PgTAP correction to no-show'
);
select is(
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)),
  '3.0', 'completed to no-show correction compensates the original award'
);

select public.correct_occurrence_attendance(
  '97100000-0000-0000-0000-000000000002', 'completed',
  'PgTAP correction back to completed'
);
select is(
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)),
  '5.0', 'no-show to completed correction restores the occurrence award'
);

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select public.submit_reservation_feedback(
  '97000000-0000-0000-0000-000000000002', 5, 'Good room.', 5, 5, 5
);
select is(
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)),
  '6.0', 'feedback adds exactly one point after a completed occurrence'
);
select throws_ok(
  $$select public.submit_reservation_feedback(
    '97000000-0000-0000-0000-000000000002', 5, 'Again.', 5, 5, 5
  )$$,
  '23505', null, 'feedback cannot award points twice for the same reservation'
);

select set_config(
  'request.jwt.claim.sub', (select external_admin_id::text from loyalty_test), false
);
select lives_ok(
  $$create temp table loyalty_offer as
    select * from public.save_loyalty_discount_offer(
      null, 'PgTAP loyalty PHP 100 off', 'Created by an external admin',
      2.5, 'fixed_amount', 10000, null, null,
      (now() at time zone 'Asia/Manila')::date - 1,
      (now() at time zone 'Asia/Manila')::date + 30, true
    )$$,
  'external admins can create fixed loyalty discount offers'
);
select is(
  (select required_points::text from loyalty_offer),
  '2.5', 'discount offers store half-point requirements'
);
select is(
  (select fixed_amount_centavos from loyalty_offer),
  10000, 'fixed discounts snapshot the centavo amount'
);

select lives_ok(
  $$create temp table loyalty_huge_offer as
    select * from public.save_loyalty_discount_offer(
      null, 'PgTAP loyalty too expensive', 'Requires more than the renter has',
      99.0, 'percentage', null, 10.0, null,
      (now() at time zone 'Asia/Manila')::date - 1,
      (now() at time zone 'Asia/Manila')::date + 30, true
  )$$,
  'external admins can create percentage loyalty discount offers'
);
select lives_ok(
  $$create temp table loyalty_admin_balance_rows as
    select * from public.loyalty_admin_balances('Loyalty Guest', 10)$$,
  'external admins can view loyalty balances'
);
select lives_ok(
  $$create temp table loyalty_admin_ledger_rows as
    select * from public.loyalty_admin_ledger(
      (select user_id from loyalty_test), 10
    )$$,
  'external admins can view renter loyalty ledgers'
);
select lives_ok(
  $$create temp table loyalty_admin_redemption_rows as
    select * from public.loyalty_admin_redemptions(null, 10)$$,
  'external admins can view legacy redemption audit rows'
);
select lives_ok(
  $$create temp table loyalty_admin_claim_rows as
    select * from public.loyalty_admin_claims(null, null, 10)$$,
  'external admins can view voucher claim history'
);
select lives_ok(
  $$select public.adjust_loyalty_points(
    (select user_id from loyalty_test), 0.5, 'PgTAP external adjustment'
  )$$,
  'external admins can manually adjust loyalty points'
);
select is(
  (select actor_id from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)
     and transaction_type = 'admin_adjustment'
   order by created_at desc
   limit 1),
  (select external_admin_id from loyalty_test),
  'manual adjustments record the external admin actor'
);

select set_config(
  'request.jwt.claim.sub', (select internal_admin_id::text from loyalty_test), false
);
select throws_ok(
  $$select * from public.loyalty_admin_balances(null, 10)$$,
  '42501', null, 'internal admins cannot view loyalty balances'
);
select throws_ok(
  $$select * from public.loyalty_admin_ledger(
    (select user_id from loyalty_test), 10
  )$$,
  '42501', null, 'internal admins cannot view loyalty ledgers'
);
select throws_ok(
  $$select * from public.loyalty_admin_redemptions(null, 10)$$,
  '42501', null, 'internal admins cannot view legacy loyalty redemptions'
);
select throws_ok(
  $$select * from public.loyalty_admin_claims(null, null, 10)$$,
  '42501', null, 'internal admins cannot view loyalty voucher history'
);
select throws_ok(
  $$select public.adjust_loyalty_points(
    (select user_id from loyalty_test), 0.5, 'Blocked internal adjustment'
  )$$,
  '42501', null, 'internal admins cannot manually adjust loyalty points'
);
select throws_ok(
  $$select public.save_loyalty_discount_offer(
    null, 'PgTAP loyalty blocked internal', '', 1.0, 'fixed_amount',
    100, null, null,
    (now() at time zone 'Asia/Manila')::date,
    (now() at time zone 'Asia/Manila')::date + 1, true
  )$$,
  '42501', null, 'internal admins cannot mutate discount offers'
);

select set_config(
  'request.jwt.claim.sub', (select user_id::text from loyalty_test), false
);
select throws_ok(
  $$select public.set_loyalty_discount_offer_active((select id from loyalty_offer), false)$$,
  '42501', null, 'renters cannot activate or deactivate discount offers'
);
select throws_ok(
  $$select public.claim_loyalty_discount((select id from loyalty_huge_offer))$$,
  '22023', null, 'renters cannot claim offers above their balance'
);
select lives_ok(
  $$create temp table loyalty_claim as
    select * from public.claim_loyalty_discount((select id from loyalty_offer))$$,
  'eligible guest renters can claim affordable discounts'
);
select is(
  (select status from loyalty_claim),
  'claimed', 'new discount vouchers begin in claimed status'
);
select is(
  (select coalesce(sum(points), 0)::text from public.loyalty_transactions
   where user_id = (select user_id from loyalty_test)),
  '4.0', 'claiming deducts points immediately and does not refund them'
);
select ok(
  ((public.get_reservation_quote(
    (select facility_id from loyalty_test),
    array[(((now() at time zone 'Asia/Manila')::date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[(((now() at time zone 'Asia/Manila')::date + 2 + time '12:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    10,
    (select id from loyalty_claim)
  )->>'discount_amount_centavos')::integer > 0),
  'reservation quotes preview an owned claimed voucher discount'
);

select * from finish();
rollback;
