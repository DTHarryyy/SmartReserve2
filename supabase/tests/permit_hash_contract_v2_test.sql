begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(13);

select has_column(
  'public', 'reservation_signature_requests', 'hash_version',
  'signature requests record their printable-hash contract'
);
select has_column(
  'public', 'reservation_user_signatures', 'hash_version',
  'submitted signatures record their printable-hash contract'
);
select has_column(
  'public', 'reservation_permits', 'hash_version',
  'generated permits record their printable-hash contract'
);

create temp table permit_hash_v2_test as
select
  '99000000-0000-0000-0000-000000000010'::uuid requester_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) admin_id,
  '99000000-0000-0000-0000-000000000020'::uuid facility_id,
  '99000000-0000-0000-0000-000000000001'::uuid request_id,
  '99100000-0000-0000-0000-000000000001'::uuid occurrence_id,
  '99200000-0000-0000-0000-000000000001'::uuid signature_request_id;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select
  '00000000-0000-0000-0000-000000000000', requester_id,
  'authenticated', 'authenticated', 'permit-hash-v2@example.test',
  'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', 'Permit Hash Requester'), now(), now(),
  '', '', '', ''
from permit_hash_v2_test
on conflict (id) do nothing;

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete, account_access_type, created_at
)
select requester_id, 'permit-hash-v2@example.test', 'Permit Hash Requester',
  'none', null, null, 'user', 'active', 'none', true, 'external_guest', now()
from permit_hash_v2_test
on conflict (id) do update
set account_status = 'active', account_access_type = 'external_guest';

insert into public.facilities (
  id, name, building, category, capacity, status, public_listing,
  facility_classification, open_days, open_time, close_time, updated_by_name,
  amenities
)
select facility_id, 'Permit Hash Test Room', 'Test Building',
  'Conference Room', 40, 'active', false, 'shared',
  array[true,true,true,true,true,true,true], '00:00', '23:59', 'Test',
  array['Wi-Fi']
from permit_hash_v2_test
on conflict (id) do nothing;

select set_config(
  'request.jwt.claim.sub', (select requester_id::text from permit_hash_v2_test), false
);

delete from public.reservation_requests
where id = '99000000-0000-0000-0000-000000000001';

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  requester_unit, facility_name, facility_building, facility_capacity,
  purpose, headcount, status, reservation_status, admin_lane,
  pricing_audience, payment_status, version, created_at
)
select request_id, requester_id, facility_id, 'Permit Hash Requester', 'user',
  'College of Information and Computing Sciences', 'Computer Laboratory 1',
  'CICS', 40, 'Permit hash contract test', 10, 'approved', 'confirmed',
  'external', 'guest', 'not_required', 1, now()
from permit_hash_v2_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at,
  booking_state, lifecycle_stage
)
select occurrence_id, request_id, facility_id, now(), now() + interval '2 hours',
  'booked', 'booked'
from permit_hash_v2_test;

insert into public.reservation_permit_items(
  request_id, source_kind, source_id, label, row_code,
  duration_minutes, billing_basis, display_order
)
select request_id, 'facility', facility_id, 'Computer Laboratory 1',
  'facility:venue', 120, 'hourly', 0
from permit_hash_v2_test;

insert into public.reservation_signature_requests(
  id, request_id, requester_id, requested_by, status, signed_at,
  reservation_version, printable_content_hash, hash_version
)
select signature_request_id, request_id, requester_id, admin_id, 'signed', now(),
  (select version from public.reservation_requests where id = request_id),
  public.permit_printable_hash(request_id), 2
from permit_hash_v2_test;

insert into public.reservation_user_signatures(
  signature_request_id, request_id, requester_id, storage_path, file_name,
  mime_type, byte_size, sha256, reservation_version,
  printable_content_hash, hash_version
)
select signature_request_id, request_id, requester_id,
  requester_id::text || '/' || request_id::text || '/signature.png',
  'signature.png', 'image/png', 100, repeat('a', 64),
  (select version from public.reservation_requests where id = request_id),
  public.permit_printable_hash(request_id), 2
from permit_hash_v2_test;

select is(
  public.permit_printable_material(
    (select request_id from permit_hash_v2_test)
  )->>'hash_contract_version',
  '2', 'printable material identifies hash contract v2'
);
select ok(
  not public.permit_printable_material(
    (select request_id from permit_hash_v2_test)
  ) ? 'version',
  'concurrency version is excluded from printable material'
);

select lives_ok(
  format(
    'select public.self_check_in_occurrence(%L::uuid, %L::uuid)',
    (select request_id from permit_hash_v2_test),
    (select occurrence_id from permit_hash_v2_test)
  ),
  'a signed payment-exempt reservation can check in'
);
select is(
  (select status from public.reservation_signature_requests
   where id = (select signature_request_id from permit_hash_v2_test)),
  'signed', 'check-in does not invalidate an unchanged printable signature'
);
select is(
  public.get_reservation_permit_readiness(
    (select request_id from permit_hash_v2_test)
  )->>'requester_signature_state',
  'current', 'readiness remains signature-current after check-in'
);

update public.reservation_requests
set payment_status = 'authorized'
where id = (select request_id from permit_hash_v2_test);
update public.reservation_requests
set payment_status = 'captured'
where id = (select request_id from permit_hash_v2_test);

select is(
  (select status from public.reservation_signature_requests
   where id = (select signature_request_id from permit_hash_v2_test)),
  'signed', 'payment state changes do not invalidate printable content'
);

update public.reservation_requests
set purpose = 'Updated printable purpose'
where id = (select request_id from permit_hash_v2_test);

select is(
  (select status from public.reservation_signature_requests
   where id = (select signature_request_id from permit_hash_v2_test)),
  'superseded', 'a printable-field change supersedes the old signature'
);
select is(
  (select count(*)::integer from public.reservation_signature_requests
   where request_id = (select request_id from permit_hash_v2_test)
     and status = 'requested'),
  1, 'a printable-field change creates exactly one updated request'
);
select is(
  public.get_reservation_permit_readiness(
    (select request_id from permit_hash_v2_test)
  )->>'requester_signature_state',
  'requested', 'readiness exposes the updated active signature request'
);
select ok(
  public.get_reservation_permit_readiness(
    (select request_id from permit_hash_v2_test)
  )->'blockers' ? 'requester_signature_required',
  'permit generation stays blocked until the updated request is signed'
);

select * from finish();
rollback;
