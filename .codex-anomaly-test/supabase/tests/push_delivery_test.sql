-- Push notification delivery (20260927100000_push_notification_delivery.sql).
--
-- Covers: enqueue_push_delivery only enqueues 'pending' when the recipient
-- has an enabled token and the kind is not suppressed by their preferences
-- (day_before_reminders for reservation_reminder), otherwise 'skipped';
-- lease_push_deliveries claims due rows, respects max_attempts, and
-- reclaims an expired lease; complete_push_delivery disables dead tokens
-- and applies backoff vs. terminal failure correctly; and push_deliveries /
-- user_push_tokens stay invisible to other users under RLS.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(21);

create temp table pud_ids as
select
  '9e000000-0000-0000-0000-000000000001'::uuid as renter_a_id,
  '9e000000-0000-0000-0000-000000000002'::uuid as renter_b_id,
  '9e000000-0000-0000-0000-000000000003'::uuid as outsider_id;

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
from (values
  ('9e000000-0000-0000-0000-000000000001'::uuid, 'pud-renter-a@example.test', 'PUD Renter A'),
  ('9e000000-0000-0000-0000-000000000002'::uuid, 'pud-renter-b@example.test', 'PUD Renter B'),
  ('9e000000-0000-0000-0000-000000000003'::uuid, 'pud-outsider@example.test', 'PUD Outsider')
) as u(id, email, full_name)
on conflict (id) do update
set email = excluded.email,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete, created_at
)
values
  ('9e000000-0000-0000-0000-000000000001', 'pud-renter-a@example.test',
   'PUD Renter A', 'none', null, null, 'user', 'active', 'none', true, now()),
  ('9e000000-0000-0000-0000-000000000002', 'pud-renter-b@example.test',
   'PUD Renter B', 'none', null, null, 'user', 'active', 'none', true, now()),
  ('9e000000-0000-0000-0000-000000000003', 'pud-outsider@example.test',
   'PUD Outsider', 'none', null, null, 'user', 'active', 'none', true, now())
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    account_status = excluded.account_status,
    verification_status = excluded.verification_status,
    onboarding_complete = excluded.onboarding_complete,
    updated_at = now();

grant select on pud_ids to authenticated;

-- Renter A has an enabled push token; renter B has none. Renter A also
-- opts out of day-before reminders specifically.
insert into public.user_push_tokens (user_id, token, platform)
select renter_a_id, 'pud-token-a-web', 'web' from pud_ids;

insert into public.notification_preferences (user_id, day_before_reminders)
select renter_a_id, false from pud_ids
on conflict (user_id) do update set day_before_reminders = excluded.day_before_reminders;

-- A default-allowed kind, with a token present, enqueues 'pending'.
insert into public.app_notifications (recipient_id, kind, title, body)
select renter_a_id, 'reservation_submitted', 'Submitted', 'Your request was submitted.'
from pud_ids;

select is(
  (select status from public.push_deliveries d
   join public.app_notifications n on n.id = d.notification_id
   where n.recipient_id = (select renter_a_id from pud_ids) and n.kind = 'reservation_submitted'),
  'pending', 'a default-allowed kind with an enabled token enqueues pending'
);
select isnt(
  (select next_attempt_at from public.push_deliveries d
   join public.app_notifications n on n.id = d.notification_id
   where n.recipient_id = (select renter_a_id from pud_ids) and n.kind = 'reservation_submitted'),
  null, 'a pending delivery has a next_attempt_at set'
);

-- reservation_reminder is suppressed by renter A's own preference.
insert into public.app_notifications (recipient_id, kind, title, body)
select renter_a_id, 'reservation_reminder', 'Reminder', 'Tomorrow.'
from pud_ids;
select is(
  (select status from public.push_deliveries d
   join public.app_notifications n on n.id = d.notification_id
   where n.recipient_id = (select renter_a_id from pud_ids) and n.kind = 'reservation_reminder'),
  'skipped', 'reservation_reminder is skipped when day_before_reminders is off'
);

-- Renter B has no enabled token at all, so even an allowed kind is skipped.
insert into public.app_notifications (recipient_id, kind, title, body)
select renter_b_id, 'reservation_submitted', 'Submitted', 'Your request was submitted.'
from pud_ids;
select is(
  (select status from public.push_deliveries d
   join public.app_notifications n on n.id = d.notification_id
   where n.recipient_id = (select renter_b_id from pud_ids) and n.kind = 'reservation_submitted'),
  'skipped', 'a recipient with no enabled token is skipped'
);

-- A disabled token does not count as an enabled token.
insert into public.user_push_tokens (user_id, token, platform, enabled)
select renter_b_id, 'pud-token-b-web', 'web', false from pud_ids;
insert into public.app_notifications (recipient_id, kind, title, body)
select renter_b_id, 'payment_submitted', 'Payment', 'Payment received.'
from pud_ids;
select is(
  (select status from public.push_deliveries d
   join public.app_notifications n on n.id = d.notification_id
   where n.recipient_id = (select renter_b_id from pud_ids) and n.kind = 'payment_submitted'),
  'skipped', 'a disabled token does not count toward eligibility'
);

-- lease_push_deliveries claims the one pending row for renter A.
create temp table pud_lease as
select (jsonb_array_elements(public.lease_push_deliveries(10, 120, 5)->'rows')->>'id')::uuid
  as delivery_id;

select is(
  (select count(*)::int from pud_lease), 1,
  'lease_push_deliveries claims exactly the one pending delivery'
);

create temp table pud_delivery_id as
select d.id as delivery_id
from public.push_deliveries d
join public.app_notifications n on n.id = d.notification_id
where n.recipient_id = (select renter_a_id from pud_ids)
  and n.kind = 'reservation_submitted';

select is(
  (select status from public.push_deliveries where id = (select delivery_id from pud_delivery_id)),
  'processing', 'the leased delivery is marked processing'
);
select is(
  (select attempt_count from public.push_deliveries where id = (select delivery_id from pud_delivery_id)),
  1, 'leasing bumps attempt_count to 1'
);

-- A second lease call finds nothing new: the row is locked and not yet due.
select is(
  (select jsonb_array_length(public.lease_push_deliveries(10, 120, 5)->'rows')),
  0, 'a delivery already leased within its lease window is not re-claimed'
);

-- Force the lease stale and re-lease with a low max_attempts so the stale
-- sweep marks it failed instead of reclaiming it.
update public.push_deliveries
set locked_at = now() - interval '10 minutes', attempt_count = 5
where id = (select delivery_id from pud_delivery_id);
select is(
  (select jsonb_array_length(public.lease_push_deliveries(10, 1, 5)->'rows')),
  0, 'a stale lease at max_attempts is swept to failed, not reclaimed'
);
select is(
  (select status from public.push_deliveries where id = (select delivery_id from pud_delivery_id)),
  'failed', 'the stale-swept delivery is marked failed'
);
select is(
  (select last_error_code from public.push_deliveries where id = (select delivery_id from pud_delivery_id)),
  'stale_processing', 'the stale sweep records stale_processing as the error code'
);

-- Now exercise reclaim of a stale lease that has not yet hit max_attempts,
-- using renter A's reservation_reminder delivery (currently skipped) is not
-- eligible, so drive this against a fresh pending delivery instead.
insert into public.app_notifications (recipient_id, kind, title, body)
select renter_a_id, 'reservation_resubmitted', 'Resubmitted', 'Your request was resubmitted.'
from pud_ids;
create temp table pud_delivery_id2 as
select d.id as delivery_id
from public.push_deliveries d
join public.app_notifications n on n.id = d.notification_id
where n.recipient_id = (select renter_a_id from pud_ids)
  and n.kind = 'reservation_resubmitted';

select public.lease_push_deliveries(10, 120, 5);
update public.push_deliveries
set locked_at = now() - interval '10 minutes'
where id = (select delivery_id from pud_delivery_id2);
select is(
  (select jsonb_array_length(public.lease_push_deliveries(10, 1, 5)->'rows')),
  1, 'a stale lease below max_attempts is reclaimed for another attempt'
);
select is(
  (select attempt_count from public.push_deliveries where id = (select delivery_id from pud_delivery_id2)),
  2, 'reclaiming a stale lease bumps attempt_count again'
);

-- complete_push_delivery: 'sent' finalizes cleanly.
select public.complete_push_delivery(
  (select delivery_id from pud_delivery_id2), 'sent', 1, null, null, 5
);
select is(
  (select status from public.push_deliveries where id = (select delivery_id from pud_delivery_id2)),
  'sent', 'complete_push_delivery marks a successful send as sent'
);

-- complete_push_delivery: a retryable failure below max_attempts goes back
-- to pending with backoff, and does not disable the token unless listed.
insert into public.app_notifications (recipient_id, kind, title, body)
select renter_a_id, 'reservation_released', 'Released', 'Your slot was released.'
from pud_ids;
create temp table pud_delivery_id3 as
select d.id as delivery_id
from public.push_deliveries d
join public.app_notifications n on n.id = d.notification_id
where n.recipient_id = (select renter_a_id from pud_ids)
  and n.kind = 'reservation_released';
select public.lease_push_deliveries(10, 120, 5);
select public.complete_push_delivery(
  (select delivery_id from pud_delivery_id3), 'failed', 0, 'fcm_unavailable', null, 5
);
select is(
  (select status from public.push_deliveries where id = (select delivery_id from pud_delivery_id3)),
  'pending', 'a retryable failure below max_attempts goes back to pending'
);
select isnt(
  (select next_attempt_at from public.push_deliveries where id = (select delivery_id from pud_delivery_id3)),
  null, 'a retryable failure schedules a future retry'
);
select is(
  (select enabled from public.user_push_tokens where token = 'pud-token-a-web'),
  true, 'a retryable failure without dead_tokens leaves the token enabled'
);

-- complete_push_delivery: a dead token is disabled even on a failure that
-- is itself terminal (attempt already at max_attempts).
update public.push_deliveries set attempt_count = 5
where id = (select delivery_id from pud_delivery_id3);
select public.lease_push_deliveries(10, 120, 6);
select public.complete_push_delivery(
  (select delivery_id from pud_delivery_id3), 'failed', 0, 'unregistered',
  array['pud-token-a-web'], 5
);
select is(
  (select enabled from public.user_push_tokens where token = 'pud-token-a-web'),
  false, 'a dead token is disabled by complete_push_delivery'
);

-- RLS: renter B cannot see renter A's tokens or any push_deliveries row.
select set_config(
  'request.jwt.claim.sub', (select renter_b_id::text from pud_ids), false
);
set local role authenticated;
select ok(
  not exists(select 1 from public.user_push_tokens where token = 'pud-token-a-web'),
  'a user cannot select another user''s push token'
);
select throws_ok(
  $$select 1 from public.push_deliveries limit 1$$,
  '42501', 'permission denied for table push_deliveries',
  'authenticated has no read access to push_deliveries at all'
);
reset role;

select * from finish();
rollback;
