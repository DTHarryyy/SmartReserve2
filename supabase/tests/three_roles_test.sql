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

select public.submit_reservation(
  '94000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'Three-role test reservation',10,
  array[(now()+interval '1 day')::timestamptz],
  array[(now()+interval '1 day 1 hour')::timestamptz],
  '[]'::jsonb,0
);

select ok(
  (select held_for_verification from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  'pending users create held requests'
);
select is(
  (select payment_amount_centavos from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  50000, 'a tampered zero client amount is replaced by the server quote'
);

update public.profiles set verification_status='verified'
where email='user@csu.edu.ph';

select isnt(
  (select held_for_verification from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  true, 'verification releases the held request'
);
select results_eq(
  $$select payment_amount_centavos,payment_status from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'$$,
  $$values (0,'not_required'::text)$$,
  'verified requests become free'
);

update public.profiles set verification_status='pending'
where email='user@csu.edu.ph';
select ok(
  (select held_for_verification from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  'reverification holds an undecided request'
);
select is(
  (select payment_amount_centavos from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  50000, 'reverification restores the authoritative quote'
);

update public.profiles set verification_status='verified'
where email='user@csu.edu.ph';
update public.reservation_requests set status='approved'
where id='94000000-0000-0000-0000-000000000001';
update public.profiles set verification_status='pending'
where email='user@csu.edu.ph';
select isnt(
  (select held_for_verification from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'),
  true, 'reverification does not hold an approved booking'
);
select results_eq(
  $$select payment_amount_centavos,payment_status from public.reservation_requests
    where id='94000000-0000-0000-0000-000000000001'$$,
  $$values (0,'not_required'::text)$$,
  'reverification does not reprice an approved booking'
);

select * from finish();
rollback;
