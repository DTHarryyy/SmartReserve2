begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(24);

create temp table external_scope_ids as
select
  '97000000-0000-0000-0000-000000000001'::uuid as external_admin_id,
  '97000000-0000-0000-0000-000000000101'::uuid as client_a_id,
  '97000000-0000-0000-0000-000000000102'::uuid as client_b_id,
  '97000000-0000-0000-0000-000000000103'::uuid as verified_id,
  '97000000-0000-0000-0000-000000000104'::uuid as suspended_id,
  '97100000-0000-0000-0000-000000000001'::uuid as facility_a_id,
  '97100000-0000-0000-0000-000000000002'::uuid as facility_b_id;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
values
  ('00000000-0000-0000-0000-000000000000',
   '97000000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'scope-external-admin@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Scope External Admin'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '97000000-0000-0000-0000-000000000101',
   'authenticated', 'authenticated', 'scope-client-a@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Scope Client A'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '97000000-0000-0000-0000-000000000102',
   'authenticated', 'authenticated', 'scope-client-b@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Scope Client B'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '97000000-0000-0000-0000-000000000103',
   'authenticated', 'authenticated', 'scope-verified@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Scope Verified User'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '97000000-0000-0000-0000-000000000104',
   'authenticated', 'authenticated', 'scope-suspended@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Scope Suspended User'), now(), now(),
   '', '', '', '')
on conflict (id) do update
set email = excluded.email,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete, created_at
)
values
  ('97000000-0000-0000-0000-000000000001',
   'scope-external-admin@example.test', 'Scope External Admin', 'none', null,
   null, 'external_admin', 'active', 'none', true, '2030-02-01 00:00+00'),
  ('97000000-0000-0000-0000-000000000101',
   'scope-client-a@example.test', 'Scope Client A', 'none', null, null,
   'user', 'active', 'none', true, '2030-02-01 00:01+00'),
  ('97000000-0000-0000-0000-000000000102',
   'scope-client-b@example.test', 'Scope Client B', 'none', null, null,
   'user', 'active', 'pending', true, '2030-02-01 00:02+00'),
  ('97000000-0000-0000-0000-000000000103',
   'scope-verified@example.test', 'Scope Verified User', 'student',
   'SCOPE-2026', 'BS Information Technology', 'user', 'active', 'verified',
   true, '2030-02-01 00:03+00'),
  ('97000000-0000-0000-0000-000000000104',
   'scope-suspended@example.test', 'Scope Suspended User', 'none', null, null,
   'user', 'suspended', 'none', true, '2030-02-01 00:04+00')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    campus_claim = excluded.campus_claim,
    campus_id = excluded.campus_id,
    unit = excluded.unit,
    role = excluded.role,
    account_status = excluded.account_status,
    verification_status = excluded.verification_status,
    onboarding_complete = excluded.onboarding_complete,
    created_at = excluded.created_at,
    updated_at = now();

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
)
values
  ('97100000-0000-0000-0000-000000000001', 'External Scope Room A',
   'Scope Building', 'External Scope Test', 40, 'active',
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test'),
  ('97100000-0000-0000-0000-000000000002', 'External Scope Room B',
   'Scope Building', 'External Scope Test', 40, 'active',
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test')
on conflict (id) do update
set name = excluded.name,
    building = excluded.building,
    category = excluded.category,
    status = excluded.status,
    updated_at = now();

insert into public.facility_admin_assignments (
  facility_id, admin_id, assignment_role, assigned_by
)
values (
  '97100000-0000-0000-0000-000000000001',
  '97000000-0000-0000-0000-000000000001',
  'manager',
  '97000000-0000-0000-0000-000000000001'
)
on conflict (facility_id, admin_id) do update
set assignment_role = excluded.assignment_role;

insert into public.facility_payment_methods (
  id, facility_id, account_name, account_number, enabled
)
values
  ('97400000-0000-0000-0000-000000000001',
   '97100000-0000-0000-0000-000000000001', 'Scope GCash A',
   '09170000001', false),
  ('97400000-0000-0000-0000-000000000002',
   '97100000-0000-0000-0000-000000000002', 'Scope GCash B',
   '09170000002', false)
on conflict (id) do update
set account_name = excluded.account_name,
    account_number = excluded.account_number,
    enabled = excluded.enabled;

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, held_for_verification, payment_amount_centavos,
  payment_status, payment_method_id, created_at, admin_lane
)
values
  ('97200000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000101',
   '97100000-0000-0000-0000-000000000001', 'Scope Client A', 'user',
   'External Scope Room A', 'Scope Building', 40, 'Assigned external lane',
   10, 'approved', 'completed', false, 50000, 'captured',
   '97400000-0000-0000-0000-000000000001', '2030-02-01 00:00+00',
   'external'),
  ('97200000-0000-0000-0000-000000000002',
   '97000000-0000-0000-0000-000000000103',
   '97100000-0000-0000-0000-000000000001', 'Scope Verified User', 'user',
   'External Scope Room A', 'Scope Building', 40, 'Assigned internal lane',
   10, 'approved', 'completed', false, 0, 'not_required', null,
   '2030-02-01 00:10+00', 'internal'),
  ('97200000-0000-0000-0000-000000000003',
   '97000000-0000-0000-0000-000000000102',
   '97100000-0000-0000-0000-000000000002', 'Scope Client B', 'user',
   'External Scope Room B', 'Scope Building', 40, 'Unassigned external lane',
   10, 'approved', 'completed', false, 50000, 'captured',
   '97400000-0000-0000-0000-000000000002', '2030-02-01 00:20+00',
   'external'),
  ('97200000-0000-0000-0000-000000000004',
   '97000000-0000-0000-0000-000000000103',
   '97100000-0000-0000-0000-000000000002', 'Scope Verified User', 'user',
   'External Scope Room B', 'Scope Building', 40, 'Verified client activity',
   10, 'approved', 'completed', false, 50000, 'captured',
   '97400000-0000-0000-0000-000000000002', '2030-02-01 00:30+00',
   'external'),
  ('97200000-0000-0000-0000-000000000005',
   '97000000-0000-0000-0000-000000000104',
   '97100000-0000-0000-0000-000000000002', 'Scope Suspended User', 'user',
   'External Scope Room B', 'Scope Building', 40, 'Suspended client activity',
   10, 'approved', 'completed', false, 50000, 'captured',
   '97400000-0000-0000-0000-000000000002', '2030-02-01 00:40+00',
   'external');

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state,
  lifecycle_stage
)
values
  ('97300000-0000-0000-0000-000000000001',
   '97200000-0000-0000-0000-000000000001',
   '97100000-0000-0000-0000-000000000001',
   '2030-02-08 00:00+00', '2030-02-08 01:00+00', 'booked', 'completed'),
  ('97300000-0000-0000-0000-000000000002',
   '97200000-0000-0000-0000-000000000002',
   '97100000-0000-0000-0000-000000000001',
   '2030-02-08 01:00+00', '2030-02-08 02:00+00', 'booked', 'completed'),
  ('97300000-0000-0000-0000-000000000003',
   '97200000-0000-0000-0000-000000000003',
   '97100000-0000-0000-0000-000000000002',
   '2030-02-08 02:00+00', '2030-02-08 03:00+00', 'booked', 'completed'),
  ('97300000-0000-0000-0000-000000000004',
   '97200000-0000-0000-0000-000000000004',
   '97100000-0000-0000-0000-000000000002',
   '2030-02-08 03:00+00', '2030-02-08 04:00+00', 'booked', 'completed'),
  ('97300000-0000-0000-0000-000000000005',
   '97200000-0000-0000-0000-000000000005',
   '97100000-0000-0000-0000-000000000002',
   '2030-02-08 04:00+00', '2030-02-08 05:00+00', 'booked', 'completed');

insert into public.payment_transactions(
  id, request_id, payer_id, payment_method_id, purpose, amount_centavos,
  reference_number, proof_path, status, idempotency_key
)
values (
  '97600000-0000-0000-0000-000000000001',
  '97200000-0000-0000-0000-000000000003',
  '97000000-0000-0000-0000-000000000102',
  '97400000-0000-0000-0000-000000000002',
  'down_payment',
  50000,
  'SCOPEPAY-B-0001',
  '97000000-0000-0000-0000-000000000102/97200000-0000-0000-0000-000000000003/proof.jpg',
  'submitted',
  '97700000-0000-0000-0000-000000000001'
);

insert into public.reservation_feedback(
  id, reservation_id, facility_id, user_id, rating, comment, created_at
)
values
  ('97500000-0000-0000-0000-000000000001',
   '97200000-0000-0000-0000-000000000001',
   '97100000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000101',
   5, 'Excellent assigned facility review', '2030-02-09 00:00+00'),
  ('97500000-0000-0000-0000-000000000002',
   '97200000-0000-0000-0000-000000000003',
   '97100000-0000-0000-0000-000000000002',
   '97000000-0000-0000-0000-000000000102',
   2, 'Unassigned facility review', '2030-02-09 01:00+00');

select set_config(
  'request.jwt.claim.sub',
  (select external_admin_id::text from external_scope_ids),
  false
);
set local role authenticated;

select ok(public.can_access_reservation('97200000-0000-0000-0000-000000000001'),
  'external admins can access assigned external-lane reservations');

select isnt(public.can_access_reservation('97200000-0000-0000-0000-000000000002'), true,
  'external admins cannot access assigned internal-lane reservations');

select isnt(public.can_access_reservation('97200000-0000-0000-0000-000000000003'), true,
  'external admins cannot access unassigned external-lane reservations operationally');

select ok(exists (
  select 1 from jsonb_array_elements(public.get_external_clients()) client
  where client->>'email' = 'scope-client-a@example.test'
), 'the global external client directory includes assigned-facility clients');

select ok(exists (
  select 1 from jsonb_array_elements(public.get_external_clients()) client
  where client->>'email' = 'scope-client-b@example.test'
), 'the global external client directory includes unassigned-facility clients');

select ok(not exists (
  select 1 from jsonb_array_elements(public.get_external_clients()) client
  where client->>'email' = 'scope-verified@example.test'
), 'the external client directory excludes campus-verified users');

select ok(not exists (
  select 1 from jsonb_array_elements(public.get_external_clients()) client
  where client->>'email' = 'scope-suspended@example.test'
), 'the external client directory excludes suspended users');

select ok(not exists (
  select 1 from jsonb_array_elements(public.get_external_clients()) client
  where client->>'email' = 'scope-external-admin@example.test'
), 'the external client directory excludes administrators');

select ok(not exists (
  select 1 from jsonb_array_elements(public.get_external_clients()) client
  where client->>'email' like 'scope-%@example.test'
    and client ?| array[
      'verification_status', 'campus_claim', 'campus_id', 'unit',
      'document_path', 'document_name', 'document_mime_type', 'documents',
      'verification_submission'
    ]
), 'the external client directory excludes verification and document fields');

select is(
  (public.feedback_admin_list(null, null, null, null, null, null, 'newest', 50, 0)->>'total')::integer,
  2,
  'feedback_admin_list reports a global total for external admins');

select ok(exists (
  select 1 from jsonb_array_elements(
    public.feedback_admin_list(null, null, null, null, null, null, 'newest', 50, 0)->'rows'
  ) row
  where row->>'facility_id' = '97100000-0000-0000-0000-000000000001'
), 'feedback_admin_list includes assigned-facility feedback');

select ok(exists (
  select 1 from jsonb_array_elements(
    public.feedback_admin_list(null, null, null, null, null, null, 'newest', 50, 0)->'rows'
  ) row
  where row->>'facility_id' = '97100000-0000-0000-0000-000000000002'
), 'feedback_admin_list includes unassigned-facility feedback');

select is(
  (public.feedback_admin_list(null, null, null, null, null, null, 'newest', 1, 0)->>'total')::integer,
  2,
  'feedback_admin_list preserves the global total before pagination');

select is(
  jsonb_array_length(public.feedback_admin_list(null, null, null, null, null, null, 'newest', 1, 0)->'rows'),
  1,
  'feedback_admin_list still applies pagination to rows');

select is((public.feedback_admin_summary(null, null, null)->>'total')::integer, 2,
  'feedback_admin_summary counts the global feedback dataset');

select is((public.feedback_admin_summary(null, null, null)->>'average')::numeric, 3.50,
  'feedback_admin_summary averages ratings across facilities');

select is((public.feedback_admin_summary(null, null, null)->>'five_star')::integer, 1,
  'feedback_admin_summary includes global five-star feedback');

select is((public.feedback_admin_summary(null, null, null)->>'low_rated')::integer, 1,
  'feedback_admin_summary includes global low-rated feedback');

select is(
  (select count(*)::integer from public.reservation_feedback
   where id in (
     '97500000-0000-0000-0000-000000000001',
     '97500000-0000-0000-0000-000000000002'
   )),
  2,
  'external admins can directly select feedback rows across facilities'
);

select is(
  (public.get_admin_report(
    '2030-02-07 23:30+00',
    '2030-02-08 05:30+00',
    'External Scope Test'
  )->'summary'->>'booked_hours')::numeric,
  4::numeric,
  'external reports count every external-lane booking, not just the assigned facility''s'
);

select set_config(
  'request.jwt.claim.sub',
  '97000000-0000-0000-0000-000000000101',
  false
);

select is(
  (select count(*)::integer from public.reservation_feedback
   where id in (
     '97500000-0000-0000-0000-000000000001',
     '97500000-0000-0000-0000-000000000002'
   )),
  1,
  'normal users can directly select only their own feedback rows'
);

select throws_ok(
  $$select public.get_external_clients()$$,
  '42501',
  'External administrator access required',
  'normal users cannot call the external client directory RPC'
);

select throws_ok(
  $$select public.feedback_admin_list(null, null, null, null, null, null, 'newest', 50, 0)$$,
  '42501',
  'Administrator access required',
  'normal users cannot call the feedback list RPC'
);

select throws_ok(
  $$select public.feedback_admin_summary(null, null, null)$$,
  '42501',
  'Administrator access required',
  'normal users cannot call the feedback summary RPC'
);

select * from finish();
rollback;
