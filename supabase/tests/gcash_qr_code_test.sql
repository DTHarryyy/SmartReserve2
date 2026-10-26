begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(11);

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
    ('9a000000-0000-0000-0000-000000000001'::uuid, 'qr-internal@example.test', 'QR Internal'),
    ('9a000000-0000-0000-0000-000000000002'::uuid, 'qr-external@example.test', 'QR External'),
    ('9a000000-0000-0000-0000-000000000003'::uuid, 'qr-renter@example.test', 'QR Renter')
) as users(id, email, full_name)
on conflict (id) do nothing;

update public.profiles set role = 'internal_admin', account_status = 'active'
where id = '9a000000-0000-0000-0000-000000000001';
update public.profiles set role = 'external_admin', account_status = 'active'
where id = '9a000000-0000-0000-0000-000000000002';

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
) values (
  '9a100000-0000-0000-0000-000000000001', 'QR Test Hall', 'QR Building',
  'QR Test', 40, 'active', array[true,true,true,true,true,true,true],
  '07:00', '19:00', 'Test'
);

create temp table qr_args as select
  '[{"audience":"student","hourly_rate_centavos":0},
    {"audience":"faculty","hourly_rate_centavos":0},
    {"audience":"staff","hourly_rate_centavos":0},
    {"audience":"guest","hourly_rate_centavos":50000}]'::jsonb as rates;
grant select on qr_args to authenticated;

select has_column('public', 'facility_payment_methods', 'qr_path',
  'GCash destinations can carry a QR');
select ok(
  (select public from storage.buckets where id = 'payment-qr'),
  'the QR bucket is public so renters can load the image'
);

-- ---------------------------------------------------------------------
-- Storage writes are limited to administrators of that facility
-- ---------------------------------------------------------------------

select set_config('request.jwt.claim.sub', '9a000000-0000-0000-0000-000000000003', true);
set local role authenticated;
select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('payment-qr', '9a100000-0000-0000-0000-000000000001/qr.png')$$,
  '42501', null, 'a renter cannot upload a QR'
);
reset role;

select set_config('request.jwt.claim.sub', '9a000000-0000-0000-0000-000000000002', true);
set local role authenticated;
select lives_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('payment-qr', '9a100000-0000-0000-0000-000000000001/qr.png')$$,
  'an External Admin can upload a QR for a facility'
);
select throws_ok(
  $$insert into storage.objects (bucket_id, name)
    values ('payment-qr', 'not-a-facility/qr.png')$$,
  '42501', null, 'a QR outside a facility folder is refused'
);

-- ---------------------------------------------------------------------
-- Saving the configuration
-- ---------------------------------------------------------------------

select lives_ok(
  $$select public.save_facility_configuration_v4(
    '9a100000-0000-0000-0000-000000000001', (select rates from qr_args), '[]'::jsonb,
    'Janna Grace Somera', '09123456789',
    'Send GCash payment to Janna Grace Somera - 09123456789. Submit the reference number and proof in SmartReserve after approval.',
    1440, 1440, 1440, 50, 'other', 'other',
    '9a100000-0000-0000-0000-000000000001/qr.png')$$,
  'an External Admin saves the GCash QR'
);
reset role;

select is(
  (select qr_path from public.facility_payment_methods
   where facility_id = '9a100000-0000-0000-0000-000000000001'
     and method_type = 'gcash' and enabled),
  '9a100000-0000-0000-0000-000000000001/qr.png',
  'the active GCash destination shows the QR'
);

select set_config('request.jwt.claim.sub', '9a000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select lives_ok(
  $$select public.save_facility_configuration_v4(
    '9a100000-0000-0000-0000-000000000001', (select rates from qr_args), '[]'::jsonb,
    'New Account Name', '09998887777', 'Pay here.',
    1440, 1440, 1440, 50, 'other', 'other',
    '9a100000-0000-0000-0000-000000000001/qr.png')$$,
  'an Internal Admin changes the GCash account and keeps the QR'
);
reset role;

select is(
  (select qr_path from public.facility_payment_methods
   where facility_id = '9a100000-0000-0000-0000-000000000001'
     and method_type = 'gcash' and enabled
     and account_number = '09998887777'),
  '9a100000-0000-0000-0000-000000000001/qr.png',
  'the QR follows a replaced GCash destination'
);

select set_config('request.jwt.claim.sub', '9a000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select throws_ok(
  $$select public.save_facility_configuration_v4(
    '9a100000-0000-0000-0000-000000000001', (select rates from qr_args), '[]'::jsonb,
    'New Account Name', '09998887777', 'Pay here.',
    1440, 1440, 1440, 50, 'other', 'other',
    'some-other-facility/qr.png')$$,
  '22023', null, 'a QR from another facility folder is refused'
);
select lives_ok(
  $$select public.save_facility_configuration_v4(
    '9a100000-0000-0000-0000-000000000001', (select rates from qr_args), '[]'::jsonb,
    'New Account Name', '09998887777', 'Pay here.',
    1440, 1440, 1440, 50, 'other', 'other', null)$$,
  'the QR can be removed'
);
reset role;

select * from finish();
rollback;
