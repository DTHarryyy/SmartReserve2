begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(6);

create temp table requested_amenity_test as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) user_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

select set_config(
  'request.jwt.claim.sub',
  (select user_id::text from requested_amenity_test),
  false
);

update public.profiles
set verification_status = 'verified', campus_claim = 'staff'
where id = (select user_id from requested_amenity_test);

update public.facilities
set open_days = array[true,true,true,true,true,true,true],
    open_time = '00:00',
    close_time = '23:59',
    amenities = array['Wi-Fi','Projector','Podium']
where id = (select facility_id from requested_amenity_test);

create temp table requested_amenity_quote as
select public.get_reservation_quote(
  (select facility_id from requested_amenity_test),
  array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
  array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
  '{}'::uuid[],
  10
) quote;

select lives_ok(
  $$select public.submit_reservation_v2(
    '99000000-0000-0000-0000-000000000001',
    (select facility_id from requested_amenity_test),
    'Catalog amenity request',
    10,
    array[((current_date + 2 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 2 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    (select coalesce(array_agg(id order by id),'{}'::uuid[])
       from public.terms_versions
       where active and (scope='global'
         or facility_id=(select facility_id from requested_amenity_test))),
    (select quote->>'pricing_fingerprint' from requested_amenity_quote),
    '[]'::jsonb,
    array['generator','Smart TV','Wi-Fi','Generator']
  )$$,
  'a valid multi-item catalog request is accepted'
);

select is(
  (select amenities from public.reservation_requests
   where id = '99000000-0000-0000-0000-000000000001'),
  array['Smart TV','Generator']::text[],
  'requested amenities are canonicalized, deduplicated, ordered, and exclude included values'
);

select is(
  (select total_amount_centavos from public.reservation_requests
   where id = '99000000-0000-0000-0000-000000000001'),
  (select (quote->>'total_amount_centavos')::integer from requested_amenity_quote),
  'additional requested amenities do not change the reservation total'
);

select is(
  (select count(*)::integer from public.reservation_amenities
   where request_id = '99000000-0000-0000-0000-000000000001'),
  0,
  'additional requested amenities do not create priced amenity rows'
);

select throws_ok(
  $$select public.submit_reservation_v2(
    '99000000-0000-0000-0000-000000000002',
    (select facility_id from requested_amenity_test),
    'Invalid amenity request',
    10,
    array[((current_date + 3 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 3 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    (select coalesce(array_agg(id order by id),'{}'::uuid[])
       from public.terms_versions
       where active and (scope='global'
         or facility_id=(select facility_id from requested_amenity_test))),
    (select public.get_reservation_quote(
      (select facility_id from requested_amenity_test),
      array[((current_date + 3 + time '10:00') at time zone 'Asia/Manila')],
      array[((current_date + 3 + time '11:00') at time zone 'Asia/Manila')],
      '{}'::uuid[],
      10
    )->>'pricing_fingerprint'),
    '[]'::jsonb,
    array['Coffee maker']
  )$$,
  '22023',
  'One or more requested amenities are not in the standard catalog',
  'custom requested amenity labels are rejected'
);

select lives_ok(
  $$select public.submit_reservation_v2(
    '99000000-0000-0000-0000-000000000003',
    (select facility_id from requested_amenity_test),
    'No amenity request',
    10,
    array[((current_date + 4 + time '10:00') at time zone 'Asia/Manila')],
    array[((current_date + 4 + time '11:00') at time zone 'Asia/Manila')],
    '{}'::uuid[],
    (select coalesce(array_agg(id order by id),'{}'::uuid[])
       from public.terms_versions
       where active and (scope='global'
         or facility_id=(select facility_id from requested_amenity_test))),
    (select public.get_reservation_quote(
      (select facility_id from requested_amenity_test),
      array[((current_date + 4 + time '10:00') at time zone 'Asia/Manila')],
      array[((current_date + 4 + time '11:00') at time zone 'Asia/Manila')],
      '{}'::uuid[],
      10
    )->>'pricing_fingerprint'),
    '[]'::jsonb
  )$$,
  'existing submissions without requested amenities still work'
);

select * from finish();
rollback;
