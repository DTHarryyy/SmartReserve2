begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(11);

select set_config(
  'request.jwt.claim.sub',
  (select id::text from public.profiles
   where role = 'internal_admin' and account_status = 'active'
   order by created_at limit 1),
  false
);

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
) values
  ('91000000-0000-0000-0000-000000000001', 'Report Active Room',
   'Test Building', 'Report Test', 40, 'active',
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test'),
  ('91000000-0000-0000-0000-000000000002', 'Report Maintenance Room',
   'Test Building', 'Report Test', 40, 'maintenance',
   array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test');

insert into public.reservation_requests (
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, decided_by, decided_by_name, decided_at, created_at
)
select
  '92000000-0000-0000-0000-000000000001', id,
  '91000000-0000-0000-0000-000000000001', 'Test Requester', role,
  'Report Active Room', 'Test Building', 40, 'Booked test', 10,
  'approved', id, full_name, '2030-01-07 00:00:00+00',
  '2030-01-06 23:45:00+00'
from public.profiles where id = auth.uid();

insert into public.reservation_occurrences (
  id, request_id, facility_id, starts_at, ends_at, booking_state
) values
  ('93000000-0000-0000-0000-000000000001',
   '92000000-0000-0000-0000-000000000001',
   '91000000-0000-0000-0000-000000000001',
   '2030-01-07 00:00:00+00', '2030-01-07 03:00:00+00', 'booked'),
  ('93000000-0000-0000-0000-000000000002',
   '92000000-0000-0000-0000-000000000001',
   '91000000-0000-0000-0000-000000000001',
   '2030-01-07 01:00:00+00', '2030-01-07 02:00:00+00', 'cancelled');

create temp table report_result as
select public.get_admin_report(
  '2030-01-06 23:30:00+00', '2030-01-07 03:30:00+00', 'Report Test'
) body;

select is(jsonb_array_length(body->'utilisation'), 1, 'only active supply is included')
from report_result;
select is((body->'summary'->>'available_hours')::numeric, 4::numeric,
  'available hours are clipped to the half-open range') from report_result;
select is((body->'summary'->>'booked_hours')::numeric, 3::numeric,
  'only booked occurrence hours count toward utilisation') from report_result;
select is((body->'summary'->>'fraction')::numeric, .75::numeric,
  'weighted utilisation is booked hours over available hours') from report_result;
select is(jsonb_array_length(body->'booked_occurrences'), 1,
  'drill-down reconciles to booked occurrences') from report_result;
select is((select (cell->>'count')::integer from jsonb_array_elements(body->'demand') cell
  where cell->>'day' = '1' and cell->>'hour' = '7'), 1,
  'an occurrence is counted in its first overlapped block') from report_result;
select is((select (cell->>'count')::integer from jsonb_array_elements(body->'demand') cell
  where cell->>'day' = '1' and cell->>'hour' = '9'), 2,
  'booked and unsuccessful demand count in every overlapped block') from report_result;
select is(jsonb_array_length(body->'demand'), 49, 'the demand grid is complete')
from report_result;
select ok(jsonb_array_length(body->'performance'->'per_admin') = 1,
  'internal administrators receive the administrator breakdown') from report_result;
select is(jsonb_array_length(public.get_admin_report(
  '2030-01-06 23:30:00+00', '2030-01-07 03:30:00+00', 'Other Category'
)->'utilisation'), 0, 'category filtering is applied by the database');
select throws_ok(
  $$select public.get_admin_report('2030-01-07 04:00:00+00', '2030-01-07 03:00:00+00', null)$$,
  '22023', 'Invalid report range', 'invalid ranges are rejected'
);

select * from finish();
rollback;
