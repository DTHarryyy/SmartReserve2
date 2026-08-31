begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(25);

create temp table dp_test as
select
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) admin_id,
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

select set_config('request.jwt.claim.sub', (select user_id::text from dp_test), false);

-- 20-50% is the only representable range for a facility's down payment policy.
select throws_ok(
  $$update public.facilities set down_payment_percent = 19
    where id = '10000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a facility cannot configure a down payment below 20 percent'
);
select throws_ok(
  $$update public.facilities set down_payment_percent = 51
    where id = '10000000-0000-0000-0000-000000000001'$$,
  '23514', null, 'a facility cannot configure a down payment above 50 percent'
);
select lives_ok(
  $$update public.facilities set down_payment_percent = 30
    where id = '10000000-0000-0000-0000-000000000001'$$,
  '30 percent is an accepted policy value'
);

-- Ceiling division on centavos, never floating point: 30 percent of an odd
-- total rounds the deposit up, not down.
select throws_ok(
  $$insert into public.reservation_requests(
    id, requester_id, facility_id, requester_name, requester_role,
    facility_name, facility_building, facility_capacity, purpose, headcount,
    status, reservation_status, admin_lane, total_amount_centavos,
    facility_amount_centavos, down_payment_percent, required_down_payment_centavos,
    created_at
  )
  select '97000000-0000-0000-0000-000000000001', user_id, facility_id,
    'Rounding Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
    'Rounding check', 10, 'pending', 'awaiting_payment', 'internal',
    1001, 1001, 30, 300, now()
  from dp_test$$,
  '23514', null, 'an under-rounded deposit (floor instead of ceiling) is rejected'
);
select lives_ok(
  $$insert into public.reservation_requests(
    id, requester_id, facility_id, requester_name, requester_role,
    facility_name, facility_building, facility_capacity, purpose, headcount,
    status, reservation_status, admin_lane, total_amount_centavos,
    facility_amount_centavos, down_payment_percent, required_down_payment_centavos,
    created_at
  )
  select '97000000-0000-0000-0000-000000000001', user_id, facility_id,
    'Rounding Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
    'Rounding check', 10, 'pending', 'awaiting_payment', 'internal',
    1001, 1001, 30, 301, now()
  from dp_test$$,
  'the correctly ceiling-rounded deposit (301 of 1001 at 30 percent) is accepted'
);

-- Verified students and faculty are exempt in the authoritative quote;
-- verified staff is not (the spec only names students and faculty).
update public.profiles
set verification_status = 'verified', campus_claim = 'faculty', unit = 'CICS'
where id = (select user_id from dp_test);
select is(
  (public.get_reservation_quote(
    (select facility_id from dp_test),
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[]
  )->>'payment_exemption'),
  'verified_faculty', 'a verified faculty requester is tagged exempt on the quote'
);

update public.profiles
set campus_claim = 'staff'
where id = (select user_id from dp_test);
select is(
  (public.get_reservation_quote(
    (select facility_id from dp_test),
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[]
  )->>'payment_exemption'),
  'none', 'a verified staff requester is not exempt'
);

-- The balance deadline is exactly the reservation start minus the facility's
-- configured lead time in minutes, not a calendar-day approximation.
update public.facilities
set balance_due_lead_minutes = 1440
where id = (select facility_id from dp_test);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, total_amount_centavos,
  facility_amount_centavos, down_payment_percent, required_down_payment_centavos,
  created_at
)
select '97000000-0000-0000-0000-000000000002', user_id, facility_id,
  'Deadline Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Deadline check', 10, 'approved', 'pending_approval', 'internal',
  10000, 10000, 30, 3000, now()
from dp_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state
)
select '97100000-0000-0000-0000-000000000002',
  '97000000-0000-0000-0000-000000000002', facility_id,
  date_trunc('day', now()) + interval '10 days' + interval '14 hours',
  date_trunc('day', now()) + interval '10 days' + interval '18 hours',
  'booked'
from dp_test;

select set_config('request.jwt.claim.sub', (select admin_id::text from dp_test), false);
select public.apply_reservation_payment_gate('97000000-0000-0000-0000-000000000002');

select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000002'),
  'awaiting_payment',
  'paid approval holds the reservation while payment is still pending'
);

select is(
  (select booking_state from public.reservation_occurrences
   where id = '97100000-0000-0000-0000-000000000002'),
  'held',
  'paid approval holds the selected occurrence slot'
);

select is(
  (select m.account_name || '|' || m.account_number
   from public.reservation_requests r
   join public.facility_payment_methods m on m.id = r.payment_method_id
   where r.id = '97000000-0000-0000-0000-000000000002'),
  'Janna Grace Somera|09123456789',
  'paid approval attaches the official GCash destination'
);

select is(
  (select count(*) from public.app_notifications
   where request_id = '97000000-0000-0000-0000-000000000002'
     and kind = 'reservation_payment_instructions'),
  1::bigint,
  'paid approval creates exactly one payment-instructions notification'
);

select like(
  (select body from public.app_notifications
   where request_id = '97000000-0000-0000-0000-000000000002'
     and kind = 'reservation_payment_instructions'
   order by created_at desc
   limit 1),
  '%Send payment to Janna Grace Somera — 09123456789%PHP 30.00%confirmed only after payment proof is verified%',
  'paid approval notifies the renter with GCash instructions and confirmation rules'
);

select is(
  (select count(*) from public.reservation_events
   where request_id = '97000000-0000-0000-0000-000000000002'
     and action = 'sent payment instructions'),
  1::bigint,
  'paid approval records exactly one payment-instructions event'
);

create temp table payment_gate_snapshot as
select
  payment_due_at,
  balance_due_at,
  (select count(*) from public.app_notifications
   where request_id = '97000000-0000-0000-0000-000000000002'
     and kind = 'reservation_payment_instructions') notification_count,
  (select count(*) from public.reservation_events
   where request_id = '97000000-0000-0000-0000-000000000002'
     and action = 'sent payment instructions') event_count
from public.reservation_requests
where id = '97000000-0000-0000-0000-000000000002';

select public.apply_reservation_payment_gate('97000000-0000-0000-0000-000000000002');

select is(
  (select payment_due_at from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000002'),
  (select payment_due_at from payment_gate_snapshot),
  'reapplying the payment gate keeps the original payment deadline'
);

select is(
  (select count(*) from public.app_notifications
   where request_id = '97000000-0000-0000-0000-000000000002'
     and kind = 'reservation_payment_instructions'),
  (select notification_count from payment_gate_snapshot),
  'reapplying the payment gate does not duplicate the notification'
);

select is(
  (select count(*) from public.reservation_events
   where request_id = '97000000-0000-0000-0000-000000000002'
     and action = 'sent payment instructions'),
  (select event_count from payment_gate_snapshot),
  'reapplying the payment gate does not duplicate the event'
);

select is(
  (select balance_due_at from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000002'),
  (select starts_at - interval '1440 minutes' from public.reservation_occurrences
   where id = '97100000-0000-0000-0000-000000000002'),
  'the balance deadline is exactly 24 hours before the reservation start'
);

select set_config('request.jwt.claim.sub', (select user_id::text from dp_test), false);

select public.submit_payment(
  '97200000-0000-0000-0000-000000000002',
  '97000000-0000-0000-0000-000000000002',
  'down_payment',
  3000,
  'DPREF123456',
  (select user_id::text from dp_test) ||
    '/97000000-0000-0000-0000-000000000002/down-payment.jpg',
  '97300000-0000-0000-0000-000000000002'
);

select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000002'),
  'awaiting_payment',
  'submitting payment proof alone does not confirm the reservation'
);

select set_config('request.jwt.claim.sub', (select admin_id::text from dp_test), false);
select public.decide_payment('97200000-0000-0000-0000-000000000002', 'verify');

select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000002'),
  'confirmed',
  'verifying enough down payment confirms the reservation'
);

select is(
  (select booking_state from public.reservation_occurrences
   where id = '97100000-0000-0000-0000-000000000002'),
  'booked',
  'verified payment converts the held occurrence back to booked'
);

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, total_amount_centavos,
  facility_amount_centavos, down_payment_percent, required_down_payment_centavos,
  created_at
)
select '97000000-0000-0000-0000-000000000003', user_id, facility_id,
  'Free Approval Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Free approval check', 10, 'approved', 'pending_approval', 'internal',
  0, 0, 30, 0, now()
from dp_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state
)
select '97100000-0000-0000-0000-000000000003',
  '97000000-0000-0000-0000-000000000003', facility_id,
  date_trunc('day', now()) + interval '12 days' + interval '9 hours',
  date_trunc('day', now()) + interval '12 days' + interval '10 hours',
  'booked'
from dp_test;

select public.apply_reservation_payment_gate('97000000-0000-0000-0000-000000000003');

select is(
  (select reservation_status from public.reservation_requests
   where id = '97000000-0000-0000-0000-000000000003'),
  'confirmed',
  'free approval confirms immediately'
);

select is(
  (select count(*) from public.reservation_permits
   where request_id = '97000000-0000-0000-0000-000000000003'
     and status = 'active'),
  1::bigint,
  'free approval issues a permit immediately'
);

select is(
  (select count(*) from public.app_notifications
   where request_id = '97000000-0000-0000-0000-000000000003'
     and kind = 'reservation_payment_instructions'),
  0::bigint,
  'free approval does not send payment instructions'
);

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
)
values (
  '97000000-0000-0000-0000-000000000004', 'Triggered GCash Room',
  'CICS', 'Test', 20, 'active',
  array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test'
);

select is(
  (select count(*) from public.facility_payment_methods
   where facility_id = '97000000-0000-0000-0000-000000000004'
     and method_type = 'gcash'
     and enabled
     and account_name = 'Janna Grace Somera'
     and account_number = '09123456789'),
  1::bigint,
  'new facilities automatically receive one active official GCash method'
);

insert into public.facility_payment_methods(
  id, facility_id, account_name, account_number, instructions, enabled
)
select '97200000-0000-0000-0000-000000000004', facility_id,
  'Historic GCash', '09175550000', 'Old account instructions', false
from dp_test;

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, total_amount_centavos,
  facility_amount_centavos, down_payment_percent, required_down_payment_centavos,
  payment_method_id, created_at
)
select '97000000-0000-0000-0000-000000000005', user_id, facility_id,
  'Historic Snapshot Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Historic payment instructions', 10, 'approved', 'confirmed', 'internal',
  10000, 10000, 30, 3000, '97200000-0000-0000-0000-000000000004', now()
from dp_test;

select is(
  (select m.account_name || '|' || m.account_number || '|' || m.instructions
   from public.reservation_requests r
   join public.facility_payment_methods m on m.id = r.payment_method_id
   where r.id = '97000000-0000-0000-0000-000000000005'),
  'Historic GCash|09175550000|Old account instructions',
  'existing reservations keep their assigned payment-method snapshot'
);

select * from finish();
rollback;
