begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(5);

create temp table actors as
select
  (select id from public.profiles where role='internal_admin' order by created_at limit 1) admin_id,
  (select id from public.profiles where role='user' order by created_at limit 1) user_id;

insert into public.reservation_requests(
  id,requester_id,facility_id,requester_name,requester_role,facility_name,
  facility_building,facility_capacity,purpose,headcount,status,
  held_for_verification,payment_amount_centavos,payment_status,created_at,
  admin_lane
)
select '95000000-0000-0000-0000-000000000001',user_id,
  '10000000-0000-0000-0000-000000000001','Paying Client','user',
  'Computer Laboratory 1','CICS',40,'Paid scope test',10,'approved',false,50000,'authorized','2030-01-01','external'
from actors
union all
select '95000000-0000-0000-0000-000000000002',user_id,
  '10000000-0000-0000-0000-000000000001','Verified Client','user',
  'Computer Laboratory 1','CICS',40,'Free scope test',10,'approved',false,0,'not_required','2030-01-01','internal'
from actors;

insert into public.reservation_occurrences(id,request_id,facility_id,starts_at,ends_at,booking_state)
values
  ('96000000-0000-0000-0000-000000000001','95000000-0000-0000-0000-000000000001',
   '10000000-0000-0000-0000-000000000001','2030-01-07 00:00+00','2030-01-07 01:00+00','booked'),
  ('96000000-0000-0000-0000-000000000002','95000000-0000-0000-0000-000000000002',
   '10000000-0000-0000-0000-000000000001','2030-01-07 02:00+00','2030-01-07 03:00+00','booked');

update public.profiles set role='external_admin'
where id=(select admin_id from actors);
select set_config('request.jwt.claim.sub',(select admin_id::text from actors),false);

select ok(public.can_access_reservation('95000000-0000-0000-0000-000000000001'),
  'external admins can access an assigned external-lane reservation');
select isnt(public.can_access_reservation('95000000-0000-0000-0000-000000000002'),true,
  'external admins cannot access an internal-lane reservation');
select ok(jsonb_array_length(public.get_external_clients())=1,
  'the external client directory contains the paying user once');
select ok(not ((public.get_external_clients()->0) ?| array['verification_status','campus_claim','campus_id','unit']),
  'the external client directory excludes verification and campus fields');
select is(
  (public.get_admin_report('2030-01-06 23:30+00','2030-01-07 03:30+00','Computer Laboratory')->'summary'->>'booked_hours')::numeric,
  1::numeric,'external reports count only assigned external-lane bookings');

select * from finish();
rollback;
