begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(8);

create temp table lane_test as
select
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) admin_id,
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  '10000000-0000-0000-0000-000000000001'::uuid assigned_facility,
  (select f.id from public.facilities f
    where f.id <> '10000000-0000-0000-0000-000000000001'
      and not exists(select 1 from public.reservation_requests r
        where r.facility_id = f.id
          and r.status in ('pending','approved','changes_requested'))
    order by f.id limit 1) other_facility;

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, admin_lane, created_at
)
select '97000000-0000-0000-0000-000000000001', user_id, assigned_facility,
  'Lane Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Internal lane case', 10, 'pending', 'internal', now()
from lane_test
union all
select '97000000-0000-0000-0000-000000000002', user_id, assigned_facility,
  'Lane Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'External lane case', 10, 'pending', 'external', now()
from lane_test
union all
select '97000000-0000-0000-0000-000000000003', user_id, other_facility,
  'Lane Test', 'user', 'Speech Laboratory', 'CICS', 40,
  'Other facility case', 10, 'pending', 'internal', now()
from lane_test;

-- Facility management is global for any active administrator (see
-- 20260830120000_global_admin_authorization.sql): there is no per-facility
-- assignment left to set up or tear down here. Only reservation-lane
-- matching still gates access, exercised below.

select set_config(
  'request.jwt.claim.sub', (select admin_id::text from lane_test), false
);

select ok(public.can_manage_facility((select assigned_facility from lane_test)),
  'an active admin can manage any facility');
select ok(public.can_manage_facility((select other_facility from lane_test)),
  'an active admin can manage a facility they have never been assigned to');
select ok(public.can_manage_reservation('97000000-0000-0000-0000-000000000001'),
  'internal admin can manage assigned internal-lane reservation');
select isnt(public.can_manage_reservation('97000000-0000-0000-0000-000000000002'), true,
  'internal admin cannot manage external-lane reservation');
select isnt(public.can_manage_reservation('97000000-0000-0000-0000-000000000003'), true,
  'internal admin cannot manage an unassigned reservation');

update public.profiles set role = 'external_admin'
where id = (select admin_id from lane_test);

select ok(public.can_manage_reservation('97000000-0000-0000-0000-000000000002'),
  'external admin can manage assigned external-lane reservation');
select isnt(public.can_manage_reservation('97000000-0000-0000-000000000001'), true,
  'external admin cannot manage internal-lane reservation');
select is(
  (select admin_lane from public.reservation_requests
    where id = '97000000-0000-0000-0000-000000000001'),
  'internal',
  'reservation lane remains snapshotted when the administrator role changes'
);

select * from finish();
rollback;
