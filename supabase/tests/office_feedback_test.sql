begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(9);

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
    ('0f000000-0000-0000-0000-000000000001'::uuid, 'office-admin@example.test', 'Office Admin'),
    ('0f000000-0000-0000-0000-000000000002'::uuid, 'office-renter@example.test', 'Office Renter'),
    ('0f000000-0000-0000-0000-000000000003'::uuid, 'office-other@example.test', 'Other Renter')
) as users(id, email, full_name)
on conflict (id) do nothing;

update public.profiles set role = 'internal_admin', account_status = 'active'
where id = '0f000000-0000-0000-0000-000000000001';
update public.profiles set account_status = 'active'
where id in ('0f000000-0000-0000-0000-000000000002', '0f000000-0000-0000-0000-000000000003');

select ok(
  'office_feedback' = any (public.system_backup_tables()),
  'office feedback is backed up'
);
select ok(
  not has_table_privilege('authenticated', 'public.office_feedback', 'insert'),
  'clients cannot insert office feedback directly'
);

select set_config('request.jwt.claim.sub', '0f000000-0000-0000-0000-000000000002', true);
set local role authenticated;
select throws_ok(
  $$select public.submit_office_feedback(6)$$,
  '23514', null, 'ratings stay within 1-5'
);
select lives_ok(
  $$select public.submit_office_feedback(4, 5, 4, 3, 'Fast approval, unclear payment steps.')$$,
  'a renter rates the office'
);
select throws_ok(
  $$select public.submit_office_feedback(5)$$,
  '22023', null, 'only one rating per day'
);
select is((select count(*) from public.office_feedback), 1::bigint,
  'the renter sees their own rating');
reset role;

select set_config('request.jwt.claim.sub', '0f000000-0000-0000-0000-000000000003', true);
set local role authenticated;
select is((select count(*) from public.office_feedback), 0::bigint,
  'other renters cannot read it');
reset role;

select set_config('request.jwt.claim.sub', '0f000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select is((select count(*) from public.office_feedback), 1::bigint,
  'admins read every rating');
select throws_ok(
  $$select public.submit_office_feedback(5)$$,
  '42501', null, 'admins cannot rate their own office'
);
reset role;

select * from finish();
rollback;
