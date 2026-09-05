begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);

create temp table lane_routing_ids as
select
  '98100000-0000-0000-0000-000000000001'::uuid as internal_admin_id,
  '98100000-0000-0000-0000-000000000002'::uuid as external_admin_id,
  '98100000-0000-0000-0000-000000000101'::uuid as verified_user_id,
  '98100000-0000-0000-0000-000000000102'::uuid as renter_user_id,
  '98200000-0000-0000-0000-000000000001'::uuid as facility_id;

update public.profiles
set account_status = 'suspended'
where role in ('internal_admin', 'external_admin');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
values
  ('00000000-0000-0000-0000-000000000000',
   '98100000-0000-0000-0000-000000000001',
   'authenticated', 'authenticated', 'lane-internal-admin@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Lane Internal Admin'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '98100000-0000-0000-0000-000000000002',
   'authenticated', 'authenticated', 'lane-external-admin@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Lane External Admin'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '98100000-0000-0000-0000-000000000101',
   'authenticated', 'authenticated', 'lane-verified-user@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Lane Verified User'), now(), now(),
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '98100000-0000-0000-0000-000000000102',
   'authenticated', 'authenticated', 'lane-renter-user@example.test',
   'test-password', now(),
   jsonb_build_object('provider', 'email', 'providers', array['email']),
   jsonb_build_object('full_name', 'Lane Renter User'), now(), now(),
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
  ('98100000-0000-0000-0000-000000000001',
   'lane-internal-admin@example.test', 'Lane Internal Admin', 'none', null,
   null, 'internal_admin', 'active', 'none', true, now()),
  ('98100000-0000-0000-0000-000000000002',
   'lane-external-admin@example.test', 'Lane External Admin', 'none', null,
   null, 'external_admin', 'active', 'none', true, now()),
  ('98100000-0000-0000-0000-000000000101',
   'lane-verified-user@example.test', 'Lane Verified User', 'student',
   'LANE-2026', 'BS Information Technology', 'user', 'active', 'verified',
   true, now()),
  ('98100000-0000-0000-0000-000000000102',
   'lane-renter-user@example.test', 'Lane Renter User', 'none', null, null,
   'user', 'active', 'none', true, now())
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

insert into public.facilities (
  id, name, building, category, capacity, status, public_listing,
  facility_classification, open_days, open_time, close_time, updated_by_name,
  amenities
)
values (
  '98200000-0000-0000-0000-000000000001',
  'Lane Routed Facility', 'Routing Building', 'Conference Room', 40, 'active',
  true, 'shared', array[true,true,true,true,true,true,true], '00:00', '23:59',
  'Lane Test', array['Wi-Fi']
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
where facility_id = (select facility_id from lane_routing_ids);

insert into public.facility_rates (
  facility_id, audience, hourly_rate_centavos, enabled
)
select (select facility_id from lane_routing_ids), audience, amount, true
from (values
  ('student'::text, 0),
  ('faculty'::text, 0),
  ('staff'::text, 0),
  ('guest'::text, 100000)
) rate(audience, amount)
on conflict (facility_id, audience) do update
set hourly_rate_centavos = excluded.hourly_rate_centavos,
    enabled = excluded.enabled;

select ok(public.has_active_admin_in_lane('internal'),
  'active internal administrators satisfy the internal reservation lane');
select ok(public.has_active_admin_in_lane('external'),
  'active external administrators satisfy the external reservation lane');
select isnt(public.has_facility_admin_lane(
    (select facility_id from lane_routing_ids), 'internal'), true,
  'facility-specific admin lane coverage still requires an assignment');
select ok(public.can_manage_facility(
    (select facility_id from lane_routing_ids),
    (select internal_admin_id from lane_routing_ids)),
  'facility management is global for any active administrator, per '
  '20260830120000_global_admin_authorization.sql');

select set_config(
  'request.jwt.claim.sub',
  (select verified_user_id::text from lane_routing_ids),
  false
);

select is(
  (select bookable from public.my_facility_access()
   where facility_id = (select facility_id from lane_routing_ids)),
  true,
  'verified users can browse-book shared facilities without a facility assignment'
);

create temp table lane_internal_quote as
select public.get_reservation_quote(
  (select facility_id from lane_routing_ids),
  array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
  array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
  '{}'::uuid[],
  10
) quote;

select lives_ok(
  $$select public.submit_reservation_v2(
    '98300000-0000-0000-0000-000000000001',
    (select facility_id from lane_routing_ids),
    'Internal lane routed request',
    10,
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    (select coalesce(array_agg(id order by id),'{}'::uuid[])
       from public.terms_versions
       where active and (scope='global'
         or facility_id=(select facility_id from lane_routing_ids))),
    (select quote->>'pricing_fingerprint' from lane_internal_quote),
    '[]'::jsonb
  )$$,
  'verified users can submit to the active internal admin lane'
);

select is(
  (select count(*)::integer from public.app_notifications
   where request_id = '98300000-0000-0000-0000-000000000001'
     and recipient_id = (select internal_admin_id from lane_routing_ids)),
  1,
  'internal lane submissions notify the active internal administrators'
);

select set_config(
  'request.jwt.claim.sub',
  (select renter_user_id::text from lane_routing_ids),
  false
);

create temp table lane_external_quote as
select public.get_reservation_quote(
  (select facility_id from lane_routing_ids),
  array[((current_date + 3 + time '10:00') at time zone 'Asia/Manila')],
  array[((current_date + 3 + time '11:00') at time zone 'Asia/Manila')],
  '{}'::uuid[],
  10
) quote;

select lives_ok(
  $$select public.submit_reservation_v2(
    '98300000-0000-0000-0000-000000000002',
    (select facility_id from lane_routing_ids),
    'External lane routed request',
    10,
    array[((current_date + 3 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 3 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    (select coalesce(array_agg(id order by id),'{}'::uuid[])
       from public.terms_versions
       where active and (scope='global'
         or facility_id=(select facility_id from lane_routing_ids))),
    (select quote->>'pricing_fingerprint' from lane_external_quote),
    '[]'::jsonb
  )$$,
  'renters can submit to the active external admin lane'
);

select is(
  (select count(*)::integer from public.app_notifications
   where request_id = '98300000-0000-0000-0000-000000000002'
     and recipient_id = (select external_admin_id from lane_routing_ids)),
  1,
  'external lane submissions notify the active external administrators'
);

update public.profiles
set account_status = 'suspended'
where id = (select external_admin_id from lane_routing_ids);

select is(
  (select bookable from public.my_facility_access()
   where facility_id = (select facility_id from lane_routing_ids)),
  false,
  'an active internal administrator does not satisfy the external lane'
);

select throws_ok(
  $$select public.get_reservation_quote(
    (select facility_id from lane_routing_ids),
    array[((current_date + 4 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 4 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    10
  )$$,
  '22023',
  'This facility does not yet have an administrator for your account type',
  'requests fail with the no-administrator error when the requester lane is empty'
);

select * from finish();
rollback;
