begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(13);

create temp table permit_test as
select
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) admin_id,
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

-- Exempt reservation: confirmed, nothing to pay -- the permit should issue
-- immediately and describe the exemption, never an amount.
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role, requester_unit,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, total_amount_centavos,
  payment_exemption, decided_by_name, decided_at, created_at
)
select '96000000-0000-0000-0000-000000000001', user_id, facility_id,
  'Permit Test Student', 'user', 'CICS',
  'Computer Laboratory 1', 'CICS', 40, 'Exempt permit check', 10,
  'approved', 'confirmed', 'internal', 0,
  'verified_student', 'Test Admin', now(), now()
from permit_test;

select set_config('request.jwt.claim.sub', (select user_id::text from permit_test), false);

create temp table exempt_permit as
select public.issue_reservation_permit('96000000-0000-0000-0000-000000000001') permit;

select ok((select (permit).status = 'active' from exempt_permit),
  'an exempt confirmed reservation is issued an active permit');
select is((select (permit).snapshot->>'payment_exemption' from exempt_permit),
  'verified_student', 'the permit snapshot records the exemption reason');
select is((select (permit).snapshot->>'remaining_balance_centavos' from exempt_permit),
  '0', 'the exempt permit shows a zero balance');

-- Paid reservation: confirmed via the down payment alone (partial), which
-- must NOT be enough to release a permit.
insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role, requester_unit,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, total_amount_centavos,
  facility_amount_centavos, required_down_payment_centavos, down_payment_percent,
  payment_exemption, decided_by_name, decided_at, created_at
)
select '96000000-0000-0000-0000-000000000002', user_id, facility_id,
  'Permit Test Renter', 'user', 'External',
  'Computer Laboratory 1', 'CICS', 40, 'Paid permit check', 10,
  'approved', 'confirmed', 'internal', 10000,
  10000, 3000, 30, 'none', 'Test Admin', now(), now()
from permit_test;

insert into public.facility_payment_methods(
  id, facility_id, account_name, account_number, enabled
)
select '96200000-0000-0000-0000-000000000001', facility_id,
  'Permit GCash', '09171234567', true
from permit_test
on conflict do nothing;

insert into public.payment_transactions(
  id, request_id, payer_id, payment_method_id, purpose, amount_centavos,
  reference_number, proof_path, status, verified_by, verified_at, idempotency_key
)
select '96300000-0000-0000-0000-000000000001', '96000000-0000-0000-0000-000000000002',
  user_id,
  (select id from public.facility_payment_methods
    where facility_id = permit_test.facility_id and enabled limit 1),
  'down_payment', 3000, 'REF-DOWN01', user_id::text || '/96000000-0000-0000-0000-000000000002/down.jpg',
  'verified', admin_id, now(), gen_random_uuid()
from permit_test;

select throws_ok(
  $$select public.issue_reservation_permit('96000000-0000-0000-0000-000000000002')$$,
  '22023', 'The permit is released only once the reservation is fully paid',
  'a down-payment-only renter cannot obtain a permit'
);

insert into public.payment_transactions(
  id, request_id, payer_id, payment_method_id, purpose, amount_centavos,
  reference_number, proof_path, status, verified_by, verified_at, idempotency_key
)
select '96300000-0000-0000-0000-000000000002', '96000000-0000-0000-0000-000000000002',
  user_id,
  (select id from public.facility_payment_methods
    where facility_id = permit_test.facility_id and enabled limit 1),
  'balance', 7000, 'REF-BAL01', user_id::text || '/96000000-0000-0000-0000-000000000002/balance.jpg',
  'verified', admin_id, now(), gen_random_uuid()
from permit_test;

create temp table paid_permit as
select public.issue_reservation_permit('96000000-0000-0000-0000-000000000002') permit;

select ok((select (permit).status = 'active' from paid_permit),
  'a fully paid renter is issued an active permit');
select is((select (permit).snapshot->>'remaining_balance_centavos' from paid_permit),
  '0', 'the fully paid permit shows a zero remaining balance');
select ok((select (permit).permit_number from paid_permit) ~ '^SR-\d{4}-\d{6}$',
  'the permit number follows the SR-YYYY-###### scheme');

-- Re-issuing with nothing materially changed returns the same permit.
select is(
  (select (permit).id from paid_permit),
  (public.issue_reservation_permit('96000000-0000-0000-0000-000000000002')).id,
  'issuing again with no material change is idempotent'
);
select is((select count(*) from public.reservation_permits
  where request_id = '96000000-0000-0000-0000-000000000002'), 1::bigint,
  'no duplicate permit row is created on the idempotent re-issue');

-- Cancelling a permitted reservation voids the permit, and the void survives
-- through the public verification lookup.
select set_config('request.jwt.claim.sub', (select admin_id::text from permit_test), false);
update public.reservation_requests
set reservation_status = 'cancelled', status = 'cancelled', decision_reason = 'No longer needed'
where id = '96000000-0000-0000-0000-000000000002';

select is((select status from public.reservation_permits
  where request_id = '96000000-0000-0000-0000-000000000002'), 'void',
  'cancelling the reservation voids its active permit');

select is(
  (public.verify_permit((select (permit).verification_token from paid_permit))->>'valid')::boolean,
  false, 'a voided permit no longer verifies as valid'
);
select is(
  public.verify_permit('does-not-exist-at-all-not-a-real-token-x')->>'valid',
  'false', 'an unknown token returns valid:false rather than an error'
);
select ok(
  not (public.verify_permit((select (permit).verification_token from exempt_permit)) ? 'total_amount_centavos'),
  'the public verification payload never includes a monetary amount'
);

select * from finish();
rollback;
