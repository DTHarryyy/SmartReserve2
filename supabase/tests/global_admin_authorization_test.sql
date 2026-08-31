-- Global lane administration (20260830120000_global_admin_authorization.sql):
-- no administrator is assigned to any specific facility any more. Coverage
-- is purely "does this reservation lane have at least one active
-- administrator", and reservation access is purely "does this admin's lane
-- match the reservation's snapshotted lane". This suite exercises the cases
-- called out in the migration plan that are not already covered by
-- admin_lane_assignment_test.sql, external_admin_scope_test.sql, and
-- reservation_anomaly_rls_test.sql.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(20);

create temp table gaa_ids as
select
  '9c000000-0000-0000-0000-000000000001'::uuid as internal_admin_1_id,
  '9c000000-0000-0000-0000-000000000002'::uuid as internal_admin_2_id,
  '9c000000-0000-0000-0000-000000000003'::uuid as external_admin_1_id,
  '9c000000-0000-0000-0000-000000000004'::uuid as verified_user_id,
  '9c000000-0000-0000-0000-000000000005'::uuid as guest_user_id,
  '9c100000-0000-0000-0000-000000000001'::uuid as facility_id,
  '9c200000-0000-0000-0000-000000000001'::uuid as internal_request_id,
  '9c200000-0000-0000-0000-000000000002'::uuid as external_request_id;

-- Every pre-existing seed administrator is suspended so this suite has
-- exclusive, deterministic control over lane coverage.
update public.profiles
set account_status = 'suspended'
where role in ('internal_admin', 'external_admin');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select
  '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  email, 'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', full_name), now(), now(), '', '', '', ''
from (values
  ('9c000000-0000-0000-0000-000000000001'::uuid, 'gaa-internal-admin-1@example.test', 'GAA Internal Admin 1'),
  ('9c000000-0000-0000-0000-000000000002'::uuid, 'gaa-internal-admin-2@example.test', 'GAA Internal Admin 2'),
  ('9c000000-0000-0000-0000-000000000003'::uuid, 'gaa-external-admin-1@example.test', 'GAA External Admin 1'),
  ('9c000000-0000-0000-0000-000000000004'::uuid, 'gaa-verified-user@example.test', 'GAA Verified User'),
  ('9c000000-0000-0000-0000-000000000005'::uuid, 'gaa-guest-user@example.test', 'GAA Guest User')
) as u(id, email, full_name)
on conflict (id) do update
set email = excluded.email,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete, created_at
)
values
  ('9c000000-0000-0000-0000-000000000001', 'gaa-internal-admin-1@example.test',
   'GAA Internal Admin 1', 'none', null, null, 'internal_admin', 'active',
   'none', true, now()),
  ('9c000000-0000-0000-0000-000000000002', 'gaa-internal-admin-2@example.test',
   'GAA Internal Admin 2', 'none', null, null, 'internal_admin', 'active',
   'none', true, now()),
  ('9c000000-0000-0000-0000-000000000003', 'gaa-external-admin-1@example.test',
   'GAA External Admin 1', 'none', null, null, 'external_admin', 'active',
   'none', true, now()),
  ('9c000000-0000-0000-0000-000000000004', 'gaa-verified-user@example.test',
   'GAA Verified User', 'student', 'GAA-2026', 'BS Information Technology',
   'user', 'active', 'verified', true, now()),
  ('9c000000-0000-0000-0000-000000000005', 'gaa-guest-user@example.test',
   'GAA Guest User', 'none', null, null, 'user', 'active', 'none', true, now())
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
    updated_at = now();

-- A facility with zero rows in facility_admin_assignments -- and zero rows
-- in the archive -- ever. Its bookability depends only on lane coverage.
insert into public.facilities (
  id, name, building, category, capacity, status, public_listing,
  facility_classification, open_days, open_time, close_time, updated_by_name,
  amenities
)
values (
  '9c100000-0000-0000-0000-000000000001', 'Unassigned GAA Room', 'GAA Building',
  'Conference Room', 40, 'active', true, 'shared',
  array[true,true,true,true,true,true,true], '00:00', '23:59', 'Test',
  array['Wi-Fi']
)
on conflict (id) do update
set status = excluded.status,
    public_listing = excluded.public_listing,
    facility_classification = excluded.facility_classification,
    open_days = excluded.open_days,
    open_time = excluded.open_time,
    close_time = excluded.close_time,
    amenities = excluded.amenities,
    updated_at = now();

delete from public.facility_admin_assignments
where facility_id = (select facility_id from gaa_ids);

insert into public.facility_rates (facility_id, audience, hourly_rate_centavos, enabled)
select (select facility_id from gaa_ids), audience, 0, true
from unnest(array['student','faculty','staff','guest']) audience
on conflict (facility_id, audience) do update
set hourly_rate_centavos = excluded.hourly_rate_centavos, enabled = true;

insert into public.reservation_requests (
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, created_at
)
values
  ((select internal_request_id from gaa_ids),
   (select verified_user_id from gaa_ids), (select facility_id from gaa_ids),
   'GAA Test', 'user', 'Unassigned GAA Room', 'GAA Building', 40,
   'Internal lane case', 10, 'approved', 'confirmed', 'internal', now()),
  ((select external_request_id from gaa_ids),
   (select guest_user_id from gaa_ids), (select facility_id from gaa_ids),
   'GAA Test', 'user', 'Unassigned GAA Room', 'GAA Building', 40,
   'External lane case', 10, 'approved', 'confirmed', 'external', now());

-- 10 setup: a legacy assignment row, inserted here (before this session
-- drops to the 'authenticated' role, which cannot write or read this table
-- or its archive) so the later authorization checks can prove its presence
-- changes nothing. facility_admin_assignments still grants authenticated
-- SELECT, but its read policy is dropped -- RLS keeps every row invisible
-- to that role even though the grant remains, so this setup step and the
-- archive-count checks all run as the privileged test-runner role instead.
insert into public.facility_admin_assignments (
  facility_id, admin_id, assignment_role, assigned_by
) values (
  (select facility_id from gaa_ids),
  (select external_admin_1_id from gaa_ids),
  'owner',
  (select external_admin_1_id from gaa_ids)
) on conflict (facility_id, admin_id) do nothing;

select is(
  (select count(*)::int from public.facility_admin_assignment_archive
   where facility_id = (select facility_id from gaa_ids)),
  0,
  '10. sanity check: this facility had no legacy assignment rows to archive at migration time'
);
select ok(
  (select count(*) from public.facility_admin_assignment_archive) > 0,
  '10. the archive retains the assignment rows that existed before this migration ran'
);

-- 1/2: Zero assignment rows does not block booking; only lane coverage does.
select ok(
  not public.has_active_admin_in_lane('internal')
    and not public.has_active_admin_in_lane('external'),
  'sanity check: every seed administrator is suspended before this suite grants coverage'
);

update public.profiles set account_status = 'active'
where id = (select internal_admin_1_id from gaa_ids);

select set_config(
  'request.jwt.claim.sub', (select verified_user_id::text from gaa_ids), false
);
set local role authenticated;

select ok(
  (select bookable from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  '1. an unassigned facility is bookable for a verified requester once one active internal admin exists'
);
select is(
  (select booking_unavailability_code from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  null::text,
  'a bookable facility carries a null booking_unavailability_code'
);

select set_config(
  'request.jwt.claim.sub', (select guest_user_id::text from gaa_ids), false
);

select is(
  (select booking_unavailability_code from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  'no_active_external_admin',
  '9. a guest requester is blocked with the external-lane no-admin code while only an internal admin is active'
);

reset role;
update public.profiles set account_status = 'active'
where id = (select external_admin_1_id from gaa_ids);
set local role authenticated;

select ok(
  (select bookable from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  '2. the same unassigned facility is bookable for a guest requester once one active external admin exists'
);

-- 6: lane isolation. 7: either admin can edit the unassigned facility.
-- 4/5: two admins active in the same lane both get management access.
select set_config(
  'request.jwt.claim.sub', (select internal_admin_1_id::text from gaa_ids), false
);

select ok(
  public.can_manage_reservation((select internal_request_id from gaa_ids)),
  '6a. an active internal admin can manage the internal-lane reservation'
);
select isnt(
  public.can_manage_reservation((select external_request_id from gaa_ids)), true,
  '6b. an active internal admin cannot manage the external-lane reservation'
);
select ok(
  public.can_manage_facility((select facility_id from gaa_ids)),
  '7a. an active internal admin can manage a facility with zero assignment rows'
);

reset role;
update public.profiles set account_status = 'active'
where id = (select internal_admin_2_id from gaa_ids);
select set_config(
  'request.jwt.claim.sub', (select internal_admin_2_id::text from gaa_ids), false
);
set local role authenticated;

select ok(
  public.can_manage_reservation((select internal_request_id from gaa_ids)),
  '4. a second active internal admin, never assigned to this facility, can also manage the same internal-lane reservation'
);
select ok(
  public.can_manage_facility((select facility_id from gaa_ids)),
  '7b. the second active internal admin can also manage the unassigned facility'
);

select set_config(
  'request.jwt.claim.sub', (select external_admin_1_id::text from gaa_ids), false
);

select ok(
  public.can_manage_reservation((select external_request_id from gaa_ids)),
  '5. the active external admin can manage the external-lane reservation'
);
select isnt(
  public.can_manage_reservation((select internal_request_id from gaa_ids)), true,
  '6c. the active external admin cannot manage the internal-lane reservation'
);
select ok(
  public.can_manage_facility((select facility_id from gaa_ids)),
  '7c. the active external admin can also manage the unassigned facility'
);

-- 8: suspending the last active internal admin blocks internal booking only.
reset role;
update public.profiles set account_status = 'suspended'
where id in (
  (select internal_admin_1_id from gaa_ids),
  (select internal_admin_2_id from gaa_ids)
);

select set_config(
  'request.jwt.claim.sub', (select verified_user_id::text from gaa_ids), false
);
set local role authenticated;

select is(
  (select booking_unavailability_code from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  'no_active_internal_admin',
  '8a. suspending the last active internal admin blocks internal booking with the internal no-admin code'
);

select set_config(
  'request.jwt.claim.sub', (select guest_user_id::text from gaa_ids), false
);

select ok(
  (select bookable from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  '8b. external booking is unaffected while an external admin remains active'
);

-- 10: the legacy assignment row inserted above changes nothing.
select ok(
  (select bookable from public.my_facility_access()
   where facility_id = (select facility_id from gaa_ids)),
  '10a. a live legacy assignment row does not change booking authorization'
);

select set_config(
  'request.jwt.claim.sub', (select external_admin_1_id::text from gaa_ids), false
);
select ok(
  public.can_manage_facility((select facility_id from gaa_ids)),
  '10b. can_manage_facility is unaffected by the presence of a legacy assignment row'
);

select throws_ok(
  $$select public.facility_assignment_directory(
    (select facility_id from gaa_ids))$$,
  '42501',
  null,
  'the legacy assignment directory RPC is no longer reachable (execute revoked from authenticated)'
);

select * from finish();
rollback;
