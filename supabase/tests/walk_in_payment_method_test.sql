begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(10);

create temp table wi_test as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id,
  (select id from public.facility_payment_methods
   where facility_id = '10000000-0000-0000-0000-000000000001'
     and method_type = 'gcash' and enabled
   order by updated_at desc limit 1) gcash_id,
  (select id from public.facility_payment_methods
   where facility_id = '10000000-0000-0000-0000-000000000001'
     and method_type = 'walk_in' and enabled
   order by updated_at desc limit 1) walk_in_id;

-- Every facility publishes exactly one cashier destination alongside GCash.
select is(
  (select count(*) from public.facility_payment_methods
   where facility_id = '10000000-0000-0000-0000-000000000001'
     and method_type = 'walk_in' and enabled),
  1::bigint,
  'the seeded facility has one active walk-in destination'
);

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
)
values (
  '96000000-0000-0000-0000-000000000001', 'Walk-in Test Room',
  'CICS', 'Test', 20, 'active',
  array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test'
);

select is(
  (select count(*) from public.facility_payment_methods
   where facility_id = '96000000-0000-0000-0000-000000000001'
     and enabled and method_type in ('gcash', 'walk_in')),
  2::bigint,
  'a new facility is seeded with both GCash and walk-in destinations'
);

-- A cashier window is not a mobile number, so the digit rule must apply only
-- to the wallet-backed methods.
select lives_ok(
  $$insert into public.facility_payment_methods(
      facility_id, method_type, account_name, account_number, instructions, enabled
    ) values (
      '10000000-0000-0000-0000-000000000001', 'walk_in',
      'CSU Aparri Cashier (annex)', 'Annex cashier window', '', false
    )$$,
  'a walk-in destination may name a window instead of a 10-15 digit number'
);
select throws_ok(
  $$insert into public.facility_payment_methods(
      facility_id, method_type, account_name, account_number, instructions, enabled
    ) values (
      '10000000-0000-0000-0000-000000000001', 'gcash',
      'Bad GCash', 'cashier window', '', false
    )$$,
  '23514', null, 'a GCash destination still requires a 10-15 digit number'
);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, total_amount_centavos,
  facility_amount_centavos, down_payment_percent, required_down_payment_centavos,
  payment_method_id, payment_due_at, created_at
)
select '96100000-0000-0000-0000-000000000001', user_id, facility_id,
  'Walk-in Payer', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Walk-in payment check', 10, 'pending', 'awaiting_payment', 'internal',
  3000, 3000, 50, 1500, gcash_id, now() + interval '1 day', now()
from wi_test;

select set_config('request.jwt.claim.sub', (select user_id::text from wi_test), false);

-- Receipt numbers are shorter than GCash references, but not empty.
select throws_ok(
  (select format(
    $$select public.submit_payment(
      '96200000-0000-0000-0000-000000000001',
      '96100000-0000-0000-0000-000000000001',
      'down_payment', 1500, 'OR', %L, '96300000-0000-0000-0000-000000000001', %L
    )$$,
    user_id::text || '/96100000-0000-0000-0000-000000000001/receipt.jpg',
    walk_in_id::text
  ) from wi_test),
  '22023', 'Provide the registrar or cashier receipt (OR) number',
  'a two-character receipt number is rejected'
);

-- The GCash rule is untouched: six characters minimum.
select throws_ok(
  (select format(
    $$select public.submit_payment(
      '96200000-0000-0000-0000-000000000002',
      '96100000-0000-0000-0000-000000000001',
      'down_payment', 1500, 'GC123', %L, '96300000-0000-0000-0000-000000000002', %L
    )$$,
    user_id::text || '/96100000-0000-0000-0000-000000000001/gcash.jpg',
    gcash_id::text
  ) from wi_test),
  '22023', 'Provide the GCash reference number',
  'a five-character GCash reference is still rejected'
);

-- A renter cannot pay to another facility's destination.
select throws_ok(
  (select format(
    $$select public.submit_payment(
      '96200000-0000-0000-0000-000000000003',
      '96100000-0000-0000-0000-000000000001',
      'down_payment', 1500, 'OR-99123', %L, '96300000-0000-0000-0000-000000000003', %L
    )$$,
    user_id::text || '/96100000-0000-0000-0000-000000000001/foreign.jpg',
    (select id::text from public.facility_payment_methods
     where facility_id = '96000000-0000-0000-0000-000000000001'
       and method_type = 'walk_in' and enabled limit 1)
  ) from wi_test),
  '22023', 'Choose a payment method published for this facility',
  'a destination from another facility is rejected'
);

select lives_ok(
  (select format(
    $$select public.submit_payment(
      '96200000-0000-0000-0000-000000000004',
      '96100000-0000-0000-0000-000000000001',
      'down_payment', 1500, 'OR-45231', %L, '96300000-0000-0000-0000-000000000004', %L
    )$$,
    user_id::text || '/96100000-0000-0000-0000-000000000001/receipt.jpg',
    walk_in_id::text
  ) from wi_test),
  'a cashier receipt is accepted as payment proof'
);

select is(
  (select payment_method_id from public.payment_transactions
   where id = '96200000-0000-0000-0000-000000000004'),
  (select walk_in_id from wi_test),
  'the transaction records the walk-in destination the renter actually used'
);

-- The reservation keeps its pinned default, so the next payment still offers
-- GCash first even after a cashier payment.
select is(
  (select payment_method_id from public.reservation_requests
   where id = '96100000-0000-0000-0000-000000000001'),
  (select gcash_id from wi_test),
  'a walk-in payment does not repin the reservation default'
);

select is(
  (select status::text from public.payment_transactions
   where id = '96200000-0000-0000-0000-000000000004'),
  'submitted',
  'a cashier receipt enters the same admin verification queue'
);

select * from finish();
rollback;
