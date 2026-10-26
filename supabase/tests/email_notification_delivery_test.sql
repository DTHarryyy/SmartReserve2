begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(14);

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
    ('e1000000-0000-0000-0000-000000000001'::uuid, 'email-on@example.test', 'Email On'),
    ('e1000000-0000-0000-0000-000000000002'::uuid, 'email-off@example.test', 'Email Off'),
    ('e1000000-0000-0000-0000-000000000003'::uuid, 'email-suspended@example.test', 'Suspended')
) as users(id, email, full_name)
on conflict (id) do nothing;

update public.profiles set account_status = 'active'
where id in ('e1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000002');
update public.profiles set account_status = 'suspended'
where id = 'e1000000-0000-0000-0000-000000000003';

insert into public.notification_preferences (user_id, email_notifications, day_before_reminders)
values
  ('e1000000-0000-0000-0000-000000000001', true, false),
  ('e1000000-0000-0000-0000-000000000002', false, true)
on conflict (user_id) do update
set email_notifications = excluded.email_notifications,
    day_before_reminders = excluded.day_before_reminders;

-- ---------------------------------------------------------------------
-- Structure and grants
-- ---------------------------------------------------------------------

select has_table('public', 'email_deliveries', 'email_deliveries table exists');
select has_column('public', 'notification_preferences', 'email_notifications',
  'users have an email opt-out');
select ok(
  not has_table_privilege('authenticated', 'public.email_deliveries', 'select'),
  'clients cannot read the email outbox'
);
select ok(
  not has_function_privilege('authenticated',
    'public.lease_email_deliveries(integer, integer, integer)', 'execute'),
  'clients cannot lease email deliveries'
);
select ok(
  'email_deliveries' = any (public.system_backup_excluded_tables()),
  'the email outbox is excluded from backups'
);

-- ---------------------------------------------------------------------
-- Enqueue gating
-- ---------------------------------------------------------------------

insert into public.app_notifications (id, recipient_id, kind, title, body) values
  ('e2000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
   'reservation_approved', 'Approved', 'Your reservation was approved.'),
  ('e2000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000002',
   'reservation_approved', 'Approved', 'Your reservation was approved.'),
  ('e2000000-0000-0000-0000-000000000003', 'e1000000-0000-0000-0000-000000000003',
   'reservation_approved', 'Approved', 'Your reservation was approved.'),
  ('e2000000-0000-0000-0000-000000000004', 'e1000000-0000-0000-0000-000000000001',
   'reservation_reminder', 'Tomorrow', 'Your reservation is tomorrow.');

select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000001'),
  'pending', 'an opted-in active user is queued'
);
select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000002'),
  'skipped', 'an opted-out user is skipped'
);
select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000003'),
  'skipped', 'a suspended account is skipped'
);
select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000004'),
  'skipped', 'the per-kind reminder toggle applies to email too'
);

-- ---------------------------------------------------------------------
-- Lease and complete
-- ---------------------------------------------------------------------

create temp table leased as
select public.lease_email_deliveries(10, 120, 5) as payload;

select is(
  (select jsonb_array_length(payload -> 'rows') from leased),
  1, 'only the deliverable row is leased'
);
select is(
  (select payload -> 'rows' -> 0 ->> 'email' from leased),
  'email-on@example.test', 'the lease carries the recipient address'
);

select public.complete_email_delivery(
  (select (payload -> 'rows' -> 0 ->> 'id')::uuid from leased),
  'failed', 'smtp_timeout', false, 5
);
select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000001'),
  'pending', 'a transient failure is retried'
);

update public.email_deliveries set next_attempt_at = now() - interval '1 second'
where notification_id = 'e2000000-0000-0000-0000-000000000001';
select public.lease_email_deliveries(10, 120, 5);
select public.complete_email_delivery(
  (select id from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000001'),
  'sent'
);
select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000001'),
  'sent', 'a successful send is recorded'
);

-- Opting out after a row was queued skips it at lease time.
insert into public.app_notifications (id, recipient_id, kind, title, body) values
  ('e2000000-0000-0000-0000-000000000005', 'e1000000-0000-0000-0000-000000000001',
   'reservation_approved', 'Approved', 'Another one.');
update public.notification_preferences set email_notifications = false
where user_id = 'e1000000-0000-0000-0000-000000000001';
select public.lease_email_deliveries(10, 120, 5);
select is(
  (select status from public.email_deliveries
   where notification_id = 'e2000000-0000-0000-0000-000000000005'),
  'skipped', 'opting out drops already-queued email'
);

select * from finish();
rollback;
