begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(41);

-- Manila wall-clock helper: day offset from today plus a HH:MI time.
create function pg_temp.mt(p_day integer, p_time text)
returns timestamptz language sql stable as $$
  select (date_trunc('day', now() at time zone 'Asia/Manila')
          + make_interval(days => p_day) + p_time::interval) at time zone 'Asia/Manila'
$$;

create function pg_temp.act_as(p_user uuid)
returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, false);
$$;

-- ---------------------------------------------------------------------
-- Fixtures: two lane admins, one campus representative, one renter and a
-- facility billed at PHP 200/hr for extra time (PHP 500/hr for guests).
-- ---------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  email, 'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', full_name), now(), now(), '', '', '', ''
from (values
  ('9a000000-0000-0000-0000-000000000001'::uuid, 'ot-internal-admin@example.test', 'OT Internal Admin'),
  ('9a000000-0000-0000-0000-000000000002'::uuid, 'ot-external-admin@example.test', 'OT External Admin'),
  ('9a000000-0000-0000-0000-000000000101'::uuid, 'ot-campus@example.test', 'OT Campus Rep'),
  ('9a000000-0000-0000-0000-000000000102'::uuid, 'ot-renter@example.test', 'OT Renter')
) as u(id, email, full_name)
on conflict (id) do nothing;

insert into public.organizational_units (id, name, unit_type, requires_representative, booking_audience)
values ('9a300000-0000-0000-0000-000000000001', 'Overtime Test College', 'college', true, 'student');
insert into public.organization_account_slots (id, unit_id)
values ('9a310000-0000-0000-0000-000000000001', '9a300000-0000-0000-0000-000000000001');

insert into public.profiles (
  id, email, full_name, campus_claim, role, account_status, verification_status,
  onboarding_complete, account_access_type, organization_slot_id, created_at
) values
  ('9a000000-0000-0000-0000-000000000001', 'ot-internal-admin@example.test',
   'OT Internal Admin', 'none', 'internal_admin', 'active', 'none', true,
   'administrator', null, now()),
  ('9a000000-0000-0000-0000-000000000002', 'ot-external-admin@example.test',
   'OT External Admin', 'none', 'external_admin', 'active', 'none', true,
   'administrator', null, now()),
  ('9a000000-0000-0000-0000-000000000101', 'ot-campus@example.test',
   'OT Campus Rep', 'student', 'user', 'active', 'verified', true,
   'organization_representative', '9a310000-0000-0000-0000-000000000001', now()),
  ('9a000000-0000-0000-0000-000000000102', 'ot-renter@example.test',
   'OT Renter', 'none', 'user', 'active', 'none', true,
   'external_guest', null, now())
on conflict (id) do update
set email = excluded.email, full_name = excluded.full_name,
    campus_claim = excluded.campus_claim, role = excluded.role,
    account_status = excluded.account_status,
    verification_status = excluded.verification_status,
    onboarding_complete = excluded.onboarding_complete,
    account_access_type = excluded.account_access_type,
    organization_slot_id = excluded.organization_slot_id;

insert into public.facilities (
  id, name, building, category, capacity, status, public_listing,
  facility_classification, open_days, open_time, close_time, updated_by_name,
  max_duration_minutes, advance_booking_days, booking_buffer_minutes,
  overtime_hourly_rate_centavos, overtime_grace_minutes
) values (
  '9a100000-0000-0000-0000-000000000001', 'Overtime Test Hall', 'Test Building',
  'Hall', 50, 'active', true, 'shared',
  array[true,true,true,true,true,true,true], '00:00', '23:59', 'Overtime Test',
  600, 60, 0, 20000, 15
);

insert into public.facility_rates (facility_id, audience, hourly_rate_centavos, enabled)
select '9a100000-0000-0000-0000-000000000001', audience, amount, true
from (values ('student', 0), ('faculty', 0), ('staff', 0), ('guest', 50000))
  as rates(audience, amount)
on conflict (facility_id, audience) do update
set hourly_rate_centavos = excluded.hourly_rate_centavos, enabled = true;

create temp table ot as
select
  '9a000000-0000-0000-0000-000000000001'::uuid internal_admin,
  '9a000000-0000-0000-0000-000000000002'::uuid external_admin,
  '9a000000-0000-0000-0000-000000000101'::uuid campus,
  '9a000000-0000-0000-0000-000000000102'::uuid renter,
  '9a100000-0000-0000-0000-000000000001'::uuid facility,
  (select id from public.facility_payment_methods
   where facility_id = '9a100000-0000-0000-0000-000000000001'
     and method_type = 'walk_in' and enabled limit 1) walk_in;

-- Confirmed reservations inserted directly so every scenario controls its
-- own clock. Buffers are zero so neighbouring slots can touch.
create function pg_temp.booking(
  p_request uuid, p_occurrence uuid, p_requester uuid, p_lane text,
  p_starts timestamptz, p_ends timestamptz, p_stage text
) returns void language sql as $$
  insert into public.reservation_requests(
    id, requester_id, facility_id, requester_name, requester_role,
    facility_name, facility_building, facility_capacity, purpose, headcount,
    status, reservation_status, admin_lane, created_at
  ) values (
    p_request, p_requester, '9a100000-0000-0000-0000-000000000001',
    'OT Booker', 'user', 'Overtime Test Hall', 'Test Building', 50,
    'Overtime scenario', 10, 'approved', 'confirmed', p_lane, now()
  );
  insert into public.reservation_occurrences(
    id, request_id, facility_id, starts_at, ends_at, booking_state,
    buffer_minutes, lifecycle_stage, checked_in_at
  ) values (
    p_occurrence, p_request, '9a100000-0000-0000-0000-000000000001',
    p_starts, p_ends, 'booked', 0, p_stage,
    case when p_stage = 'checked_in' then p_starts end
  );
$$;

-- ---------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------

select is(
  public.after_hours_minutes(pg_temp.mt(2, '15:00'), pg_temp.mt(2, '17:30')),
  30, 'only the minutes after 17:00 count as after-hours'
);
select is(
  public.extra_time_billable_minutes('internal', pg_temp.mt(2, '16:50'), pg_temp.mt(2, '17:20'), 15),
  60, 'campus overtime counts only after-hours minutes, beyond the grace, in whole hours'
);
select is(
  public.extra_time_billable_minutes('external', pg_temp.mt(2, '10:00'), pg_temp.mt(2, '10:15'), 15),
  0, 'overtime within the 15-minute grace is free'
);

-- ---------------------------------------------------------------------
-- Campus quote: free until 5 PM, after-hours at the overtime rate
-- ---------------------------------------------------------------------

select pg_temp.act_as((select campus from ot));

select is(
  (public.get_reservation_quote((select facility from ot),
    array[pg_temp.mt(2, '13:00')], array[pg_temp.mt(2, '16:00')])->>'total_amount_centavos')::integer,
  0, 'a campus booking entirely before 5 PM is free'
);
select is(
  (public.get_reservation_quote((select facility from ot),
    array[pg_temp.mt(2, '15:00')], array[pg_temp.mt(2, '19:00')])->>'total_amount_centavos')::integer,
  40000, 'a 3-7 PM campus booking pays two after-hours hours'
);
select is(
  (public.get_reservation_quote((select facility from ot),
    array[pg_temp.mt(2, '15:00')], array[pg_temp.mt(2, '17:30')])->>'total_amount_centavos')::integer,
  20000, 'a started after-hours hour is billed as a whole hour'
);
select is(
  (select (q->>'payment_exemption') || ':' || (q->>'after_hours_minutes') || ':' ||
          ((q->>'required_down_payment_centavos')::integer > 0)::text
   from public.get_reservation_quote((select facility from ot),
     array[pg_temp.mt(2, '15:00')], array[pg_temp.mt(2, '19:00')]) q),
  'internal_user:120:true',
  'the campus quote exposes the after-hours minutes and requires a down payment'
);

select pg_temp.act_as((select renter from ot));
select is(
  (public.get_reservation_quote((select facility from ot),
    array[pg_temp.mt(2, '10:00')], array[pg_temp.mt(2, '12:00')])->>'total_amount_centavos')::integer,
  100000, 'renter pricing is unchanged (guest hourly rate for every hour)'
);

-- A real submission keeps the quoted after-hours price.
select pg_temp.act_as((select campus from ot));
select lives_ok(
  format(
    $$select public.submit_reservation_v2(
      '9a200000-0000-0000-0000-000000000001', %L, 'After-hours rehearsal', 10,
      array[%L::timestamptz], array[%L::timestamptz], '{}'::uuid[],
      array(select id from public.terms_versions
            where active and (scope = 'global' or facility_id = %L)),
      public.get_reservation_quote(%L, array[%L::timestamptz], array[%L::timestamptz])->>'pricing_fingerprint'
    )$$,
    (select facility from ot), pg_temp.mt(2, '15:00'), pg_temp.mt(2, '19:00'),
    (select facility from ot), (select facility from ot),
    pg_temp.mt(2, '15:00'), pg_temp.mt(2, '19:00')
  ),
  'a campus requester can submit an after-hours booking'
);
select is(
  (select total_amount_centavos || ':' || payment_exemption
   from public.reservation_requests where id = '9a200000-0000-0000-0000-000000000001'),
  '40000:internal_user',
  'the submitted campus booking keeps its after-hours price'
);
select ok(
  pg_get_functiondef('public.submit_reservation_v3'::regproc)
    not like '%total_amount_centavos = 0%',
  'submit_reservation_v3 no longer zeroes campus prices'
);

update public.reservation_occurrences set booking_state = 'booked'
where request_id = '9a200000-0000-0000-0000-000000000001';
select pg_temp.act_as((select internal_admin from ot));
select public.apply_reservation_payment_gate('9a200000-0000-0000-0000-000000000001');
select is(
  (select reservation_status from public.reservation_requests
   where id = '9a200000-0000-0000-0000-000000000001'),
  'awaiting_payment',
  'an after-hours campus booking waits for payment after approval'
);

-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------

select pg_temp.booking('9a210000-0000-0000-0000-000000000001', '9a220000-0000-0000-0000-000000000001',
  (select campus from ot), 'internal', pg_temp.mt(3, '13:00'), pg_temp.mt(3, '15:00'), 'booked');
select pg_temp.booking('9a210000-0000-0000-0000-000000000002', '9a220000-0000-0000-0000-000000000002',
  (select campus from ot), 'internal', pg_temp.mt(4, '16:00'), pg_temp.mt(4, '17:00'), 'booked');
select pg_temp.booking('9a210000-0000-0000-0000-000000000003', '9a220000-0000-0000-0000-000000000003',
  (select renter from ot), 'external', pg_temp.mt(4, '18:00'), pg_temp.mt(4, '19:00'), 'booked');
select pg_temp.booking('9a210000-0000-0000-0000-000000000004', '9a220000-0000-0000-0000-000000000004',
  (select renter from ot), 'external', pg_temp.mt(5, '22:30'), pg_temp.mt(5, '23:30'), 'booked');
select pg_temp.booking('9a210000-0000-0000-0000-000000000005', '9a220000-0000-0000-0000-000000000005',
  (select renter from ot), 'external', pg_temp.mt(5, '10:00'), pg_temp.mt(5, '11:00'), 'booked');

select pg_temp.act_as((select campus from ot));
select is(
  (select amount_centavos || ':' || status from public.request_time_extension(
    '9a210000-0000-0000-0000-000000000001', '9a220000-0000-0000-0000-000000000001', 1,
    'Rehearsal ran long', null, '9a230000-0000-0000-0000-000000000001')),
  '0:requested',
  'a campus extension that ends before 5 PM is free but still needs approval'
);
select is(
  (select id from public.request_time_extension(
    '9a210000-0000-0000-0000-000000000001', '9a220000-0000-0000-0000-000000000001', 1,
    'Rehearsal ran long', null, '9a230000-0000-0000-0000-000000000001')),
  (select id from public.reservation_time_charges
   where occurrence_id = '9a220000-0000-0000-0000-000000000001'),
  'retrying with the same idempotency key returns the same request'
);
select throws_ok(
  $$select public.request_time_extension(
    '9a210000-0000-0000-0000-000000000001', '9a220000-0000-0000-0000-000000000001', 1,
    null, null, '9a230000-0000-0000-0000-000000000002')$$,
  '22023', 'An extension request is already waiting for review',
  'only one extension can wait for review per booking'
);

select pg_temp.act_as((select internal_admin from ot));
select is(
  (select status from public.decide_time_extension(
    (select id from public.reservation_time_charges
     where occurrence_id = '9a220000-0000-0000-0000-000000000001'), 'approve', null)),
  'approved', 'the lane administrator approves the extension'
);
select is(
  (select ends_at from public.reservation_occurrences
   where id = '9a220000-0000-0000-0000-000000000001'),
  pg_temp.mt(3, '16:00'), 'approval moves the booked end time on the calendar'
);

select pg_temp.act_as((select campus from ot));
select is(
  (select amount_centavos from public.request_time_extension(
    '9a210000-0000-0000-0000-000000000002', '9a220000-0000-0000-0000-000000000002', 1,
    null, null, '9a230000-0000-0000-0000-000000000003')),
  20000, 'a campus extension from 5 PM to 6 PM is charged one after-hours hour'
);
select pg_temp.act_as((select internal_admin from ot));
select public.decide_time_extension(
  (select id from public.reservation_time_charges
   where occurrence_id = '9a220000-0000-0000-0000-000000000002'), 'approve', null);
select is(
  (select (s->>'payable_total_centavos') || ':' || (s->>'outstanding_amount_centavos') || ':' || (s->>'status')
   from public.reservation_payment_summary('9a210000-0000-0000-0000-000000000002') s),
  '20000:20000:unpaid',
  'the approved extension becomes an outstanding balance on a free booking'
);
select isnt(
  (select payment_method_id from public.reservation_requests
   where id = '9a210000-0000-0000-0000-000000000002'),
  null, 'a free campus booking gets a payment method once it owes money'
);

select pg_temp.act_as((select campus from ot));
select throws_ok(
  $$select public.request_time_extension(
    '9a210000-0000-0000-0000-000000000002', '9a220000-0000-0000-0000-000000000002', 1,
    null, null, '9a230000-0000-0000-0000-000000000004')$$,
  '23P01', 'The facility is booked right after this slot',
  'an extension cannot run into the next booking'
);
select throws_ok(
  $$select public.request_time_extension(
    '9a210000-0000-0000-0000-000000000005', '9a220000-0000-0000-0000-000000000005', 1,
    null, null, '9a230000-0000-0000-0000-000000000005')$$,
  '42501', 'Reservation access denied',
  'only the requester can ask to extend a booking'
);

select pg_temp.act_as((select renter from ot));
select throws_ok(
  $$select public.request_time_extension(
    '9a210000-0000-0000-0000-000000000004', '9a220000-0000-0000-0000-000000000004', 1,
    null, null, '9a230000-0000-0000-0000-000000000006')$$,
  '22023', null,
  'an extension cannot run past the closing time'
);
select is(
  (select amount_centavos from public.request_time_extension(
    '9a210000-0000-0000-0000-000000000005', '9a220000-0000-0000-0000-000000000005', 1,
    null, null, '9a230000-0000-0000-0000-000000000007')),
  20000, 'a renter extension is charged at any hour'
);
select pg_temp.act_as((select internal_admin from ot));
select throws_ok(
  $$select public.decide_time_extension(
    (select id from public.reservation_time_charges
     where occurrence_id = '9a220000-0000-0000-0000-000000000005'), 'approve', null)$$,
  '42501', 'Reservation access denied',
  'an administrator cannot decide extensions outside their lane'
);
select pg_temp.act_as((select external_admin from ot));
select is(
  (select status from public.decide_time_extension(
    (select id from public.reservation_time_charges
     where occurrence_id = '9a220000-0000-0000-0000-000000000005'), 'decline', 'Room is being cleaned')),
  'declined', 'the renter lane administrator can decline an extension'
);

-- ---------------------------------------------------------------------
-- Checkout and overtime
-- ---------------------------------------------------------------------

select pg_temp.booking('9a210000-0000-0000-0000-000000000006', '9a220000-0000-0000-0000-000000000006',
  (select campus from ot), 'internal', pg_temp.mt(-1, '15:00'), pg_temp.mt(-1, '17:00'), 'checked_in');
select pg_temp.booking('9a210000-0000-0000-0000-000000000007', '9a220000-0000-0000-0000-000000000007',
  (select campus from ot), 'internal', pg_temp.mt(-2, '15:00'), pg_temp.mt(-2, '17:00'), 'checked_in');
select pg_temp.booking('9a210000-0000-0000-0000-000000000008', '9a220000-0000-0000-0000-000000000008',
  (select campus from ot), 'internal', pg_temp.mt(-3, '13:00'), pg_temp.mt(-3, '15:00'), 'checked_in');
select pg_temp.booking('9a210000-0000-0000-0000-000000000009', '9a220000-0000-0000-0000-000000000009',
  (select campus from ot), 'internal', pg_temp.mt(-4, '15:00'), pg_temp.mt(-4, '17:00'), 'checked_in');
select pg_temp.booking('9a210000-0000-0000-0000-000000000010', '9a220000-0000-0000-0000-000000000010',
  (select renter from ot), 'external', pg_temp.mt(-5, '10:00'), pg_temp.mt(-5, '11:00'), 'checked_in');
select pg_temp.booking('9a210000-0000-0000-0000-000000000011', '9a220000-0000-0000-0000-000000000011',
  (select renter from ot), 'external', now() - interval '30 minutes', now() + interval '30 minutes', 'checked_in');
select pg_temp.booking('9a210000-0000-0000-0000-000000000012', '9a220000-0000-0000-0000-000000000012',
  (select renter from ot), 'external', now() - interval '100 minutes', now() - interval '40 minutes', 'checked_in');

select pg_temp.act_as((select internal_admin from ot));
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000006',
    '9a220000-0000-0000-0000-000000000006', pg_temp.mt(-1, '17:10'))->>'amount_centavos')::integer,
  0, 'ten minutes past 5 PM is within the grace'
);
select is(
  (select lifecycle_stage || ':' || overtime_minutes || ':' ||
          (select reservation_status from public.reservation_requests
           where id = '9a210000-0000-0000-0000-000000000006')
   from public.reservation_occurrences where id = '9a220000-0000-0000-0000-000000000006'),
  'completed:10:completed',
  'checkout completes the booking and records the minutes over'
);
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000007',
    '9a220000-0000-0000-0000-000000000007', pg_temp.mt(-2, '17:20'))->>'amount_centavos')::integer,
  20000, 'twenty minutes past 5 PM bills one hour for a campus booking'
);
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000008',
    '9a220000-0000-0000-0000-000000000008', pg_temp.mt(-3, '15:40'))->>'amount_centavos')::integer,
  0, 'campus overtime before 5 PM is free'
);
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000009',
    '9a220000-0000-0000-0000-000000000009', pg_temp.mt(-4, '18:30'))->>'amount_centavos')::integer,
  40000, '90 minutes past 5 PM bills two hours'
);

select pg_temp.act_as((select external_admin from ot));
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000010',
    '9a220000-0000-0000-0000-000000000010', pg_temp.mt(-5, '11:16'))->>'amount_centavos')::integer,
  20000, 'a renter 16 minutes over is billed one hour'
);

select pg_temp.act_as((select renter from ot));
select throws_ok(
  format($$select public.check_out_occurrence('9a210000-0000-0000-0000-000000000011',
    '9a220000-0000-0000-0000-000000000011', %L::timestamptz)$$, now() - interval '5 minutes'),
  '42501', 'Only an administrator can record an earlier checkout time',
  'requesters cannot backdate their checkout'
);
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000011',
    '9a220000-0000-0000-0000-000000000011', null, null, null,
    '9a240000-0000-0000-0000-000000000001')->>'amount_centavos')::integer,
  0, 'a requester can check out early at no charge'
);
select is(
  (public.check_out_occurrence('9a210000-0000-0000-0000-000000000011',
    '9a220000-0000-0000-0000-000000000011', null, null, null,
    '9a240000-0000-0000-0000-000000000001')->>'duplicate')::boolean,
  true, 'a retried checkout is idempotent'
);

select pg_temp.act_as((select external_admin from ot));
select public.record_occurrence_attendance('9a210000-0000-0000-0000-000000000012',
  '9a220000-0000-0000-0000-000000000012', 'complete');
select is(
  (select amount_centavos from public.reservation_time_charges
   where occurrence_id = '9a220000-0000-0000-0000-000000000012' and kind = 'overtime'),
  20000, 'the administrator "Mark completed" action also bills overtime'
);

-- ---------------------------------------------------------------------
-- Paying and waiving extra charges after completion
-- ---------------------------------------------------------------------

select pg_temp.act_as((select campus from ot));
select lives_ok(
  (select format(
    $$select public.submit_payment(
      '9a250000-0000-0000-0000-000000000001', '9a210000-0000-0000-0000-000000000007',
      'adjustment', 20000, 'OR-77881', %L, '9a260000-0000-0000-0000-000000000001', %L)$$,
    campus::text || '/9a210000-0000-0000-0000-000000000007/receipt.jpg', walk_in::text)
   from ot),
  'overtime can be paid on a completed reservation'
);
select throws_ok(
  (select format(
    $$select public.submit_payment(
      '9a250000-0000-0000-0000-000000000002', '9a210000-0000-0000-0000-000000000007',
      'adjustment', 100, 'OR-77882', %L, '9a260000-0000-0000-0000-000000000002', %L)$$,
    campus::text || '/9a210000-0000-0000-0000-000000000007/extra.jpg', walk_in::text)
   from ot),
  '22023', null,
  'nothing more can be paid once the extra charges are covered'
);

select pg_temp.act_as((select internal_admin from ot));
select public.decide_payment('9a250000-0000-0000-0000-000000000001', 'verify');
select is(
  (select s->>'status' from public.reservation_payment_summary('9a210000-0000-0000-0000-000000000007') s),
  'fully_paid', 'the verified overtime payment settles the reservation'
);
select throws_ok(
  $$select public.waive_time_charge(
    (select id from public.reservation_time_charges
     where occurrence_id = '9a220000-0000-0000-0000-000000000007'), 'Goodwill')$$,
  '22023', 'This charge is already paid or has a payment under review',
  'a paid charge cannot be waived'
);
select public.waive_time_charge(
  (select id from public.reservation_time_charges
   where occurrence_id = '9a220000-0000-0000-0000-000000000009'), 'First-time courtesy');
select is(
  (select (s->>'outstanding_amount_centavos') || ':' || (s->>'status')
   from public.reservation_payment_summary('9a210000-0000-0000-0000-000000000009') s),
  '0:not_required', 'a waived charge no longer counts toward the balance'
);

select * from finish();
rollback;
