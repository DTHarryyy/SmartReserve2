begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);

create temp table public_calendar_actors as
select
  (select id from public.profiles
   where role = 'user' order by created_at limit 1) user_id,
  (select id from public.profiles
   where role = 'internal_admin' order by created_at limit 1) admin_id;

select set_config(
  'request.jwt.claim.sub',
  (select admin_id::text from public_calendar_actors),
  false
);

insert into public.facilities (
  id, name, building, category, capacity, status, public_listing, open_days,
  open_time, close_time, updated_by_name, archived_at
) values
  ('97000000-0000-0000-0000-000000000001', 'Public Calendar Active',
   'Test Building', 'Calendar Test', 40, 'active', true,
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test', null),
  ('97000000-0000-0000-0000-000000000002', 'Public Calendar Private',
   'Test Building', 'Calendar Test', 40, 'active', false,
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test', null),
  ('97000000-0000-0000-0000-000000000003', 'Public Calendar Archived',
   'Test Building', 'Calendar Test', 40, 'active', true,
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test', now()),
  ('97000000-0000-0000-0000-000000000004', 'Public Calendar Maintenance',
   'Test Building', 'Calendar Test', 40, 'maintenance', true,
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test', null);

insert into public.reservation_requests (
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, decided_by, decided_by_name, decided_at, created_at, admin_lane
)
select
  request_id, user_id, facility_id, requester_name, 'user',
  facility_name, 'Test Building', 40, purpose, 10,
  'approved', admin_id, 'Admin', '2030-01-01 00:00+00',
  '2030-01-01 00:00+00', 'external'
from public_calendar_actors
cross join (values
  ('98000000-0000-0000-0000-000000000001'::uuid,
   '97000000-0000-0000-0000-000000000001'::uuid,
   'Visible Requester', 'Public Calendar Active', 'Sensitive visible purpose'),
  ('98000000-0000-0000-0000-000000000002'::uuid,
   '97000000-0000-0000-0000-000000000002'::uuid,
   'Private Requester', 'Public Calendar Private', 'Sensitive private purpose'),
  ('98000000-0000-0000-0000-000000000003'::uuid,
   '97000000-0000-0000-0000-000000000003'::uuid,
   'Archived Requester', 'Public Calendar Archived', 'Sensitive archived purpose'),
  ('98000000-0000-0000-0000-000000000004'::uuid,
   '97000000-0000-0000-0000-000000000004'::uuid,
   'Maintenance Requester', 'Public Calendar Maintenance', 'Sensitive maintenance purpose')
) data(request_id, facility_id, requester_name, facility_name, purpose);

insert into public.reservation_occurrences (
  id, request_id, facility_id, starts_at, ends_at, booking_state
) values
  ('99000000-0000-0000-0000-000000000001',
   '98000000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000001',
   '2030-01-07 00:00+00', '2030-01-07 01:00+00', 'booked'),
  ('99000000-0000-0000-0000-000000000002',
   '98000000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000001',
   '2030-01-07 02:00+00', '2030-01-07 03:00+00', 'held'),
  ('99000000-0000-0000-0000-000000000003',
   '98000000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000001',
   '2030-01-07 04:00+00', '2030-01-07 05:00+00', 'requested'),
  ('99000000-0000-0000-0000-000000000004',
   '98000000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000001',
   '2030-01-07 06:00+00', '2030-01-07 07:00+00', 'cancelled'),
  ('99000000-0000-0000-0000-000000000005',
   '98000000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000001',
   '2030-01-07 08:00+00', '2030-01-07 09:00+00', 'expired'),
  ('99000000-0000-0000-0000-000000000006',
   '98000000-0000-0000-0000-000000000002',
   '97000000-0000-0000-0000-000000000002',
   '2030-01-07 10:00+00', '2030-01-07 11:00+00', 'booked'),
  ('99000000-0000-0000-0000-000000000007',
   '98000000-0000-0000-0000-000000000003',
   '97000000-0000-0000-0000-000000000003',
   '2030-01-07 12:00+00', '2030-01-07 13:00+00', 'booked'),
  ('99000000-0000-0000-0000-000000000008',
   '98000000-0000-0000-0000-000000000004',
   '97000000-0000-0000-0000-000000000004',
   '2030-01-07 14:00+00', '2030-01-07 15:00+00', 'booked'),
  ('99000000-0000-0000-0000-000000000009',
   '98000000-0000-0000-0000-000000000001',
   '97000000-0000-0000-0000-000000000001',
   '2030-03-07 00:00+00', '2030-03-07 01:00+00', 'booked');

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000000',
  false
);
select throws_ok(
  $$select count(*) from public.public_reservation_calendar(
      array['97000000-0000-0000-0000-000000000001'::uuid],
      '2030-01-07 00:00+00', '2030-01-08 00:00+00'
    )$$,
  '42501', null, 'missing-profile callers are denied'
);

select set_config(
  'request.jwt.claim.sub',
  (select admin_id::text from public_calendar_actors),
  false
);
select throws_ok(
  $$select count(*) from public.public_reservation_calendar(
      array['97000000-0000-0000-0000-000000000001'::uuid],
      '2030-01-07 00:00+00', '2030-01-08 00:00+00'
    )$$,
  '42501', null, 'administrator callers are denied'
);

update public.profiles set account_status = 'suspended'
where id = (select user_id from public_calendar_actors);
select set_config(
  'request.jwt.claim.sub',
  (select user_id::text from public_calendar_actors),
  false
);
select throws_ok(
  $$select count(*) from public.public_reservation_calendar(
      array['97000000-0000-0000-0000-000000000001'::uuid],
      '2030-01-07 00:00+00', '2030-01-08 00:00+00'
    )$$,
  '42501', null, 'suspended users are denied'
);

update public.profiles set account_status = 'active', verification_status = 'none'
where id = (select user_id from public_calendar_actors);
select is((select count(*)::integer from public.public_reservation_calendar(
  array[
    '97000000-0000-0000-0000-000000000001'::uuid,
    '97000000-0000-0000-0000-000000000002'::uuid,
    '97000000-0000-0000-0000-000000000003'::uuid,
    '97000000-0000-0000-0000-000000000004'::uuid
  ],
  '2030-01-07 00:00+00', '2030-01-08 00:00+00'
)), 2, 'unverified active users receive only unavailable public active slots');

update public.profiles set verification_status = 'pending'
where id = (select user_id from public_calendar_actors);
select is((select count(*)::integer from public.public_reservation_calendar(
  array['97000000-0000-0000-0000-000000000001'::uuid],
  '2030-01-07 00:00+00', '2030-01-08 00:00+00'
)), 2, 'pending users receive the same sanitized schedule');

update public.profiles set verification_status = 'rejected'
where id = (select user_id from public_calendar_actors);
select is((select count(*)::integer from public.public_reservation_calendar(
  array['97000000-0000-0000-0000-000000000001'::uuid],
  '2030-01-07 00:00+00', '2030-01-08 00:00+00'
)), 2, 'rejected users receive the same sanitized schedule');

update public.profiles set verification_status = 'verified'
where id = (select user_id from public_calendar_actors);
select is((select count(*)::integer from public.public_reservation_calendar(
  array['97000000-0000-0000-0000-000000000001'::uuid],
  '2030-01-07 00:00+00', '2030-01-08 00:00+00'
)), 2, 'verified users receive the same sanitized schedule');

select results_eq(
  $$select starts_at from public.public_reservation_calendar(
      array['97000000-0000-0000-0000-000000000001'::uuid],
      '2030-01-07 00:00+00', '2030-01-08 00:00+00'
    ) order by starts_at$$,
  $$values ('2030-01-07 00:00+00'::timestamptz),
           ('2030-01-07 02:00+00'::timestamptz)$$,
  'only held and booked public active occurrences are returned'
);

select throws_ok(
  $$select count(*) from public.public_reservation_calendar(
      array['97000000-0000-0000-0000-000000000001'::uuid],
      '2030-01-08 00:00+00', '2030-01-07 00:00+00'
    )$$,
  '22023', null, 'invalid ranges are rejected'
);

create temp table public_calendar_result as
select * from public.public_reservation_calendar(
  array['97000000-0000-0000-0000-000000000001'::uuid],
  '2030-01-07 00:00+00', '2030-01-08 00:00+00'
);

select is((select count(*)::integer
  from information_schema.columns
  where table_name = 'public_calendar_result'), 3,
  'the result exposes exactly three columns');

select isnt(to_jsonb(result) ?| array[
  'id', 'request_id', 'requester_id', 'requester_name', 'purpose',
  'headcount', 'booking_state', 'payment_status'
], true, 'the result contains no sensitive reservation columns')
from public_calendar_result result
limit 1;

select * from finish();
rollback;
