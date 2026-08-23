begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(7);

create temp table payment_test as
select
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) admin_id,
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

select set_config(
  'request.jwt.claim.sub', (select user_id::text from payment_test), false
);

update public.profiles
set verification_status = 'verified', campus_claim = 'student'
where id = (select user_id from payment_test);

update public.facilities
set open_days = array[true,true,true,true,true,true,true],
    open_time = '00:00', close_time = '23:59'
where id = (select facility_id from payment_test);

select is(public.requester_admin_lane(), 'internal',
  'verified campus requester derives the internal lane');
select is(public.requester_pricing_audience(), 'student',
  'verified student derives the student pricing audience');
select ok(public.has_facility_admin_lane(
  (select facility_id from payment_test), 'internal'
), 'backfilled facility has internal lane coverage');

-- A verified student is payment-exempt: the quote must zero the total
-- (and therefore the deposit) regardless of the facility's configured
-- student rate, and the exemption must be visible on the quote itself.
select is(
  (public.get_reservation_quote(
    (select facility_id from payment_test),
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[]
  )->>'required_down_payment_centavos')::integer,
  0,
  'a verified student is payment-exempt: the quote deposit is zero'
);

-- Staff stays in the internal lane (so admin coverage is unaffected) but is
-- deliberately NOT exempt -- the spec only names students and faculty.
update public.profiles
set campus_claim = 'staff'
where id = (select user_id from payment_test);

select is(
  (public.get_reservation_quote(
    (select facility_id from payment_test),
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[]
  )->>'required_down_payment_centavos')::integer,
  25000,
  'a verified staff requester is not exempt and pays a centavo-safe deposit'
);

update public.profiles
set campus_claim = 'student'
where id = (select user_id from payment_test);

select throws_ok(
  $$select public.get_reservation_quote(
    '10000000-0000-0000-0000-000000000001',
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    array['ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid]
  )$$,
  '22023', 'One or more amenities are unavailable for this facility',
  'arbitrary amenity ids are rejected'
);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, admin_lane, created_at
)
select '98000000-0000-0000-0000-000000000001', user_id, facility_id,
  'Payment Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Payment constraint', 10, 'approved', 'internal', now()
from payment_test;

insert into public.facility_payment_methods(
  id, facility_id, account_name, account_number, enabled
)
select '98000000-0000-0000-0000-000000000002', facility_id,
  'Test GCash', '09171234567', false
from payment_test;

select throws_ok(
  $$insert into public.payment_transactions(
    request_id, payer_id, payment_method_id, purpose, amount_centavos,
    reference_number, proof_path, idempotency_key
  ) values (
    '98000000-0000-0000-0000-000000000001',
    (select user_id from payment_test),
    '98000000-0000-0000-0000-000000000002',
    'down_payment', 0, '123456', 'invalid', gen_random_uuid()
  )$$,
  '23514', null,
  'non-positive payment transactions are rejected'
);

select * from finish();
rollback;
