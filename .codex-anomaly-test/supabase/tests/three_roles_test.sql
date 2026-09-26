begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(15);

select set_eq(
  $$select distinct role from public.profiles order by role$$,
  $$values ('internal_admin'::text), ('user'::text)$$,
  'seeded profiles use only supported roles'
);

select throws_ok(
  $$update public.profiles set role='student' where email='user@csu.edu.ph'$$,
  '23514', null, 'legacy account roles are rejected'
);

select is(
  (select campus_claim from public.profiles where email='user@csu.edu.ph'),
  'none', 'claim metadata is independent from role migration'
);

select is(
  public.reservation_quote_centavos(
    '10000000-0000-0000-0000-000000000001',
    array[(now()+interval '1 day')::timestamptz],
    array[(now()+interval '1 day 1 hour')::timestamptz]
  ), 50000, 'the server calculates the current small-room hourly rate'
);
select is(
  public.reservation_quote_centavos(
    '10000000-0000-0000-0000-000000000004',
    array[(now()+interval '1 day')::timestamptz],
    array[(now()+interval '1 day 1 hour')::timestamptz]
  ), 100000, 'the server applies the medium-room multiplier'
);
select is(
  public.reservation_quote_centavos(
    '10000000-0000-0000-0000-000000000003',
    array[(now()+interval '1 day')::timestamptz],
    array[(now()+interval '1 day 1 hour')::timestamptz]
  ), 150000, 'the server applies the large-room multiplier'
);
select is(
  public.reservation_quote_centavos(
    '10000000-0000-0000-0000-000000000001',
    array[(now()+interval '1 day')::timestamptz,(now()+interval '8 days')::timestamptz],
    array[(now()+interval '1 day 1 hour')::timestamptz,(now()+interval '8 days 1 hour')::timestamptz]
  ), 100000, 'recurring quotes total every occurrence'
);

update public.profiles set verification_status='pending'
where email='user@csu.edu.ph';
select set_config('request.jwt.claim.sub',
  (select id::text from public.profiles where email='user@csu.edu.ph'),false);

select is(
  public.requester_admin_lane(), 'external',
  'pending campus users derive the external admin lane'
);
select is(public.requester_pricing_audience(), 'guest',
  'pending campus users receive the guest pricing audience');

insert into public.reservation_requests(
  id,requester_id,facility_id,requester_name,requester_role,facility_name,
  facility_building,facility_capacity,purpose,headcount,status,admin_lane
)
select '94000000-0000-0000-0000-000000000001',id,
  '10000000-0000-0000-0000-000000000001','Lane snapshot','user',
  'Computer Laboratory 1','CICS',40,'Stable lane test',10,'pending','external'
from public.profiles where email='user@csu.edu.ph';

update public.profiles set verification_status='verified',campus_claim='student'
where email='user@csu.edu.ph';

select is(public.requester_admin_lane(), 'internal',
  'verified campus users derive the internal admin lane');
select is(public.requester_pricing_audience(), 'student',
  'verified student claim derives student pricing');
select is((select admin_lane from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  'external','verification changes do not transfer an existing reservation');
select is((select count(*)::integer from public.facility_rates
    where facility_id='10000000-0000-0000-0000-000000000001'),
  4,'every facility starts with four explicit audience rates');
select ok(public.has_facility_admin_lane(
    '10000000-0000-0000-0000-000000000001','internal'),
  'the ownership backfill preserves internal-lane coverage');
select isnt(public.has_facility_admin_lane(
    '10000000-0000-0000-0000-000000000001','external'),true,
  'external coverage is not granted globally during migration');

select * from finish();
rollback;
