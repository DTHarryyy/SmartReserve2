begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(9);

create temp table auth_profile_contract_ids as
select
  'b1000000-0000-0000-0000-000000000001'::uuid as admin_id,
  'b1000000-0000-0000-0000-000000000002'::uuid as suspended_user_id,
  'b1000000-0000-0000-0000-000000000003'::uuid as missing_profile_id,
  'b1000000-0000-0000-0000-000000000004'::uuid as representative_id,
  'b1010000-0000-0000-0000-000000000001'::uuid as unit_id,
  'b1020000-0000-0000-0000-000000000001'::uuid as slot_id;

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
from (
  values
    ((select admin_id from auth_profile_contract_ids), 'session-admin@example.test', 'Session Admin'),
    ((select suspended_user_id from auth_profile_contract_ids), 'session-suspended@example.test', 'Suspended User'),
    ((select missing_profile_id from auth_profile_contract_ids), 'session-missing@example.test', 'Missing Profile'),
    ((select representative_id from auth_profile_contract_ids), 'session-representative@example.test', 'Session Representative')
) as users(id, email, full_name)
on conflict (id) do update
set email = excluded.email,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

-- The auth-user trigger normally creates this row. Remove it deliberately to
-- cover the recovery path for an authenticated account without a profile.
delete from public.profiles
where id = (select missing_profile_id from auth_profile_contract_ids);

insert into public.organizational_units (
  id, name, code, unit_type, active, requires_representative, booking_audience
) values (
  (select unit_id from auth_profile_contract_ids), 'Session Contract Organization',
  'SCO', 'student_organization', true, true, 'student'
) on conflict (id) do update
set active = true,
    requires_representative = true,
    booking_audience = 'student',
    updated_at = now();

insert into public.organization_account_slots (id, unit_id, label, active)
values (
  (select slot_id from auth_profile_contract_ids),
  (select unit_id from auth_profile_contract_ids),
  'Session representative', true
) on conflict (id) do update
set unit_id = excluded.unit_id,
    label = excluded.label,
    active = true,
    updated_at = now();

insert into public.profiles (
  id, email, full_name, campus_claim, role, account_status,
  account_access_type, verification_status, onboarding_complete,
  must_change_password, suspension_reason, suspended_until, organization_slot_id
)
values
  ((select admin_id from auth_profile_contract_ids), 'session-admin@example.test',
   'Session Admin', 'none', 'internal_admin', 'active', 'administrator',
   'verified', true, false, null, null, null),
  ((select suspended_user_id from auth_profile_contract_ids), 'session-suspended@example.test',
   'Suspended User', 'none', 'user', 'suspended', 'external_guest',
   'none', true, false, 'Expired test suspension', current_date - 1, null),
  ((select representative_id from auth_profile_contract_ids), 'session-representative@example.test',
   'Session Representative', 'student', 'user', 'active', 'organization_representative',
   'verified', true, false, null, null,
   (select slot_id from auth_profile_contract_ids))
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    campus_claim = excluded.campus_claim,
    role = excluded.role,
    account_status = excluded.account_status,
    account_access_type = excluded.account_access_type,
    verification_status = excluded.verification_status,
    onboarding_complete = excluded.onboarding_complete,
    must_change_password = excluded.must_change_password,
    suspension_reason = excluded.suspension_reason,
    suspended_until = excluded.suspended_until,
    organization_slot_id = excluded.organization_slot_id,
    updated_at = now();

set local role authenticated;
select set_config('request.jwt.claim.sub', '', false);
select throws_ok(
  $$select public.get_my_session_profile()$$,
  '42501', 'Sign in required',
  'unauthenticated callers cannot load a session profile'
);

select set_config(
  'request.jwt.claim.sub',
  (select admin_id::text from auth_profile_contract_ids),
  false
);
select is(
  public.get_my_session_profile() ->> 'id',
  (select admin_id::text from auth_profile_contract_ids),
  'administrator receives their own profile'
);
select is(
  public.get_my_session_profile() ->> 'role',
  'internal_admin',
  'administrator profile includes its role'
);
select is(
  public.get_my_session_profile() ->> 'organization_slot_id',
  null::text,
  'administrator safely has no organization-slot assignment'
);

select set_config(
  'request.jwt.claim.sub',
  (select suspended_user_id::text from auth_profile_contract_ids),
  false
);
select is(
  public.get_my_session_profile() ->> 'id',
  (select suspended_user_id::text from auth_profile_contract_ids),
  'a user receives only their own profile'
);
select is(
  public.get_my_session_profile() ->> 'account_status',
  'active',
  'an expired suspension is normalized before the profile is returned'
);

select set_config(
  'request.jwt.claim.sub',
  (select representative_id::text from auth_profile_contract_ids),
  false
);
select is(
  public.get_my_session_profile() ->> 'organization_slot_id',
  (select slot_id::text from auth_profile_contract_ids),
  'representative profile includes its assigned organization slot'
);
select is(
  public.get_my_session_profile() ->> 'organization_unit_name',
  'Session Contract Organization',
  'representative profile includes its organization unit'
);

select set_config(
  'request.jwt.claim.sub',
  (select missing_profile_id::text from auth_profile_contract_ids),
  false
);
select is(
  public.get_my_session_profile(),
  null::jsonb,
  'an authenticated user without a profile receives null'
);

select * from finish();
rollback;
