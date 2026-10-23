begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(72);

-- ---------------------------------------------------------------------
-- Structure and grants
-- ---------------------------------------------------------------------

select has_table('public', 'system_backups', 'system_backups table exists');

select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('list_system_backups', 'create_system_backup',
       'get_system_backup_payload', 'import_system_backup',
       'delete_system_backup', 'restore_system_backup',
       'run_automatic_system_backup')),
  7::bigint, 'all backup and recovery functions exist'
);

select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proname like '%system_backup%' or p.proname like '\_restore\_system%')
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('system_backup_tables')),
  0::bigint, 'anon cannot execute any backup function'
);

select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proname = 'run_automatic_system_backup'
       or p.proname like '\_%system\_%'
       or p.proname like '\_restore\_system%')
     and has_function_privilege('authenticated', p.oid, 'execute')),
  0::bigint, 'authenticated cannot execute the automatic backup or any internal helper'
);

select is(
  has_function_privilege('service_role', 'public.run_automatic_system_backup()', 'execute'),
  true, 'service_role can run the automatic backup'
);

select is(
  has_table_privilege('authenticated', 'public.system_backups', 'SELECT'),
  false, 'authenticated has no direct SELECT on system_backups'
);

select is(
  (select count(*) from pg_attribute
   where attrelid = 'public.system_backup_summary'::regtype::text::regclass
     and attname = 'payload' and not attisdropped),
  0::bigint, 'the client summary type never carries the payload'
);

-- Every public table is either covered or deliberately excluded, so a future
-- migration cannot silently fall out of backups.
select is(
  (select count(*) from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
     and c.relname <> all (public.system_backup_tables())
     and c.relname <> all (public.system_backup_excluded_tables())),
  0::bigint, 'every public table is covered or explicitly excluded'
);

select is(
  (select count(*) from unnest(public.system_backup_tables()) t
   where t = any (public.system_backup_excluded_tables())),
  0::bigint, 'no table is both covered and excluded'
);

select is(
  (select count(*) from unnest(public.system_backup_tables()) t
   where to_regclass(format('public.%I', t)) is null),
  0::bigint, 'every covered table exists'
);

select is(
  (select count(*) from pg_constraint c
   join pg_class child on child.oid = c.conrelid
   join pg_class parent on parent.oid = c.confrelid
   where c.contype = 'f' and child.relnamespace = 'public'::regnamespace
     and child.relname = any (public.system_backup_tables())
     and parent.relnamespace = 'public'::regnamespace
     and parent.relname = any (public.system_backup_tables())
     and child.oid <> parent.oid
     and array_position(public.system_backup_tables(), parent.relname::text)
       > array_position(public.system_backup_tables(), child.relname::text)
     and not exists (
       select 1 from public.system_backup_deferred_columns() d
       join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where d.table_name = child.relname::text and d.column_name = a.attname::text)),
  0::bigint, 'the restore order puts every parent before its children'
);

select is(
  (select count(*) from pg_constraint c
   join pg_class child on child.oid = c.conrelid
   where c.contype = 'f' and child.relnamespace = 'public'::regnamespace
     and child.relname = any (public.system_backup_tables())
     and array_length(c.conkey, 1) > 1),
  0::bigint, 'no covered table uses a composite foreign key'
);

select is(
  (select count(*) from cron.job where jobname = 'smartreserve-nightly-backup'),
  1::bigint, 'the nightly backup is scheduled'
);

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------

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
  ('bb000000-0000-0000-0000-000000000001'::uuid, 'backup-internal-admin@example.test', 'Backup Internal Admin'),
  ('bb000000-0000-0000-0000-000000000002'::uuid, 'backup-external-admin@example.test', 'Backup External Admin'),
  ('bb000000-0000-0000-0000-000000000003'::uuid, 'backup-user@example.test', 'Backup User'),
  ('bb000000-0000-0000-0000-000000000005'::uuid, 'backup-ghost@example.test', 'Backup Ghost'),
  ('bb000000-0000-0000-0000-000000000006'::uuid, 'backup-org@example.test', 'Backup Org Representative')
) as u(id, email, full_name)
on conflict (id) do nothing;

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete
)
values
  ('bb000000-0000-0000-0000-000000000001', 'backup-internal-admin@example.test',
   'Backup Internal Admin', 'none', null, null, 'internal_admin', 'active', 'none', true),
  ('bb000000-0000-0000-0000-000000000002', 'backup-external-admin@example.test',
   'Backup External Admin', 'none', null, null, 'external_admin', 'active', 'none', true),
  ('bb000000-0000-0000-0000-000000000003', 'backup-user@example.test',
   'Backup User', 'student', 'BK-3', 'BS IT', 'user', 'active', 'verified', true),
  ('bb000000-0000-0000-0000-000000000005', 'backup-ghost@example.test',
   'Backup Ghost', 'none', null, null, 'user', 'active', 'none', true),
  ('bb000000-0000-0000-0000-000000000006', 'backup-org@example.test',
   'Backup Org Representative', 'none', null, null, 'user', 'active', 'none', true)
on conflict (id) do update
set role = excluded.role, account_status = excluded.account_status,
    verification_status = excluded.verification_status, updated_at = now();

create temp table bk as select
  'bb000000-0000-0000-0000-000000000001'::uuid as ia_id,
  'bb000000-0000-0000-0000-000000000002'::uuid as ea_id,
  'bb000000-0000-0000-0000-000000000003'::uuid as user_id,
  'bb000000-0000-0000-0000-000000000004'::uuid as late_id,
  'bb000000-0000-0000-0000-000000000005'::uuid as ghost_id,
  'bb000000-0000-0000-0000-000000000006'::uuid as org_id,
  'bb100000-0000-0000-0000-000000000001'::uuid as f1_id,
  'bb100000-0000-0000-0000-000000000002'::uuid as f2_id,
  'bb200000-0000-0000-0000-000000000001'::uuid as r1_id,
  'bb200000-0000-0000-0000-000000000002'::uuid as r2_id,
  'bb300000-0000-0000-0000-000000000001'::uuid as o1_id,
  'bb300000-0000-0000-0000-000000000002'::uuid as o2_id,
  'bb400000-0000-0000-0000-000000000001'::uuid as slot_id,
  'bb500000-0000-0000-0000-000000000001'::uuid as application_id;
grant select on bk to authenticated, service_role;

create temp table bk_runs (name text primary key, backup_id uuid, result jsonb);
grant all on bk_runs to authenticated, service_role;

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
)
select f1_id, 'Backup Room 1', 'Backup Building', 'Backup Test', 40, 'active',
  array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test'
from bk;

insert into public.reservation_requests (
  id, requester_id, facility_id, requester_name, requester_role, facility_name,
  facility_building, facility_capacity, purpose, headcount, status,
  reservation_status, admin_lane
)
select r1_id, user_id, f1_id, 'Backup User', 'user', 'Backup Room 1',
  'Backup Building', 40, 'Original reservation', 10, 'pending', 'pending_approval', 'internal'
from bk;

insert into public.reservation_occurrences (id, request_id, facility_id, starts_at, ends_at, booking_state)
select o1_id, r1_id, f1_id, now() + interval '5 days', now() + interval '5 days 1 hour', 'requested'
from bk;

insert into public.reservation_events (request_id, actor_id, actor_name, actor_role, action, details)
select r1_id, user_id, 'Backup User', 'user', 'submitted', '{}'::jsonb from bk;

insert into public.notification_preferences (user_id)
select user_id from bk union all select ghost_id from bk;

-- Both dependency cycles are exercised: profiles <-> organization slots and
-- reservation_requests <-> loyalty discount applications.
insert into public.organizational_units (id, name, unit_type, requires_representative, booking_audience)
values ('bb600000-0000-0000-0000-000000000001', 'Backup Test Office', 'office', true, 'staff');
insert into public.organization_account_slots (id, unit_id)
select slot_id, 'bb600000-0000-0000-0000-000000000001' from bk;
update public.profiles p
set account_access_type = 'organization_representative', organization_slot_id = bk.slot_id
from bk where p.id = bk.org_id;

insert into public.loyalty_discount_offers (
  id, name, required_points, discount_kind, fixed_amount_centavos, valid_from, valid_until
) values (
  'bb700000-0000-0000-0000-000000000001', 'Backup Offer', 5, 'fixed_amount', 5000,
  current_date, current_date + 30
);
insert into public.loyalty_discount_claims (
  id, user_id, offer_id, offer_name, discount_kind, fixed_amount_centavos,
  required_points, expiry_date, points_spent
)
select 'bb800000-0000-0000-0000-000000000001', user_id,
  'bb700000-0000-0000-0000-000000000001', 'Backup Offer', 'fixed_amount', 5000,
  5, current_date + 30, 5
from bk;
insert into public.loyalty_discount_applications (id, claim_id, reservation_id, discount_amount_centavos)
select application_id, 'bb800000-0000-0000-0000-000000000001', r1_id, 5000 from bk;
update public.reservation_requests q set loyalty_discount_application_id = bk.application_id
from bk where q.id = bk.r1_id;

-- ---------------------------------------------------------------------
-- Authorization
-- ---------------------------------------------------------------------

select set_config('request.jwt.claim.sub', (select user_id::text from bk), false);
set local role authenticated;

select throws_ok(
  $$select public.create_system_backup('nope')$$, '42501',
  'Administrator access required', 'a regular user cannot create a backup'
);
select throws_ok(
  $$select * from public.list_system_backups()$$, '42501',
  'Administrator access required', 'a regular user cannot list backups'
);
select throws_ok(
  $$select public.restore_system_backup(gen_random_uuid(), 'because', 'RESTORE')$$, '42501',
  'Administrator access required', 'a regular user cannot restore a backup'
);
select throws_ok(
  $$select public.get_system_backup_payload(gen_random_uuid())$$, '42501',
  'Administrator access required', 'a regular user cannot download a backup'
);

reset role;
select set_config('request.jwt.claim.sub', (select ea_id::text from bk), false);
set local role authenticated;
select lives_ok(
  $$select public.create_system_backup('external admin backup')$$,
  'an external admin can create a backup'
);
select throws_ok(
  $$select public.import_system_backup('{}'::jsonb, 'x')$$, '42501',
  'Internal administrator access required', 'an external admin cannot import a backup file'
);

reset role;
select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;
select lives_ok(
  $$select public.create_system_backup('internal admin backup')$$,
  'an internal admin can create a backup'
);

-- ---------------------------------------------------------------------
-- Backup contents
-- ---------------------------------------------------------------------

insert into bk_runs (name, backup_id)
select 'main', id from public.create_system_backup('round trip');

reset role;

select is(
  (select (table_counts ->> 'facilities')::bigint from public.system_backups
   where id = (select backup_id from bk_runs where name = 'main')),
  (select count(*) from public.facilities),
  'the facility count in the backup matches the live table'
);
select is(
  (select checksum from public.system_backups
   where id = (select backup_id from bk_runs where name = 'main')),
  (select encode(extensions.digest(payload::text, 'sha256'), 'hex') from public.system_backups
   where id = (select backup_id from bk_runs where name = 'main')),
  'the stored checksum is the sha256 of the payload'
);
select is(
  (select size_bytes from public.system_backups
   where id = (select backup_id from bk_runs where name = 'main')),
  (select octet_length(payload::text)::bigint from public.system_backups
   where id = (select backup_id from bk_runs where name = 'main')),
  'the stored size matches the payload'
);
select is(
  (select payload -> 'tables' -> 'reservation_requests' -> 0 ->> 'purpose'
   from public.system_backups where id = (select backup_id from bk_runs where name = 'main')),
  'Original reservation', 'reservation rows are captured in the payload'
);
select isnt(
  (select count(*) from public.audit_entries
   where entity_type = 'system' and action = 'created a system backup'
     and entity_id = (select backup_id from bk_runs where name = 'main')),
  0::bigint, 'creating a backup is written to the audit log'
);

-- ---------------------------------------------------------------------
-- Round trip: change everything, then restore
-- ---------------------------------------------------------------------

update public.facilities set capacity = 99 where id = (select f1_id from bk);
delete from public.reservation_requests where id = (select r1_id from bk);
update public.organization_account_slots set label = 'Changed after the backup' where id = (select slot_id from bk);
insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
)
select f2_id, 'Backup Room 2', 'Backup Building', 'Backup Test', 20, 'active',
  array[true,true,true,true,true,true,true], '07:00', '19:00', 'Test'
from bk;
insert into public.reservation_requests (
  id, requester_id, facility_id, requester_name, requester_role, facility_name,
  facility_building, facility_capacity, purpose, headcount, status,
  reservation_status, admin_lane
)
select r2_id, user_id, f2_id, 'Backup User', 'user', 'Backup Room 2',
  'Backup Building', 20, 'Created after the backup', 5, 'pending', 'pending_approval', 'internal'
from bk;
insert into public.reservation_occurrences (id, request_id, facility_id, starts_at, ends_at, booking_state)
select o2_id, r2_id, f2_id, now() + interval '6 days', now() + interval '6 days 1 hour', 'requested'
from bk;

-- A profile created after the backup survives; one whose auth account was
-- deleted cannot come back.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select '00000000-0000-0000-0000-000000000000', late_id, 'authenticated', 'authenticated',
  'backup-late@example.test', 'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', 'Backup Late'), now(), now(), '', '', '', ''
from bk;
insert into public.profiles (id, email, full_name, role, account_status, onboarding_complete)
select late_id, 'backup-late@example.test', 'Backup Late', 'user', 'active', true from bk
on conflict (id) do nothing;
delete from auth.users where id = (select ghost_id from bk);

select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;

select throws_ok(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'main'), 'round trip test', 'restore')$$,
  '22023', 'Type RESTORE to confirm', 'the confirmation text is case-sensitive'
);
select throws_ok(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'main'), '  ', 'RESTORE')$$,
  '22023', 'A reason is required', 'a restore needs a reason'
);

reset role;
select is(
  (select capacity from public.facilities where id = (select f1_id from bk)), 99,
  'a rejected restore changed nothing'
);
select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;

update bk_runs set result = public.restore_system_backup(
  (select backup_id from bk_runs where name = 'main'), 'round trip test', 'RESTORE')
where name = 'main';

reset role;

select is(
  (select capacity from public.facilities where id = (select f1_id from bk)), 40,
  'the facility edit was rolled back'
);
select is(
  (select count(*) from public.reservation_requests where id = (select r1_id from bk)
     and purpose = 'Original reservation'),
  1::bigint, 'the deleted reservation is back'
);
select is(
  (select count(*) from public.reservation_occurrences where id = (select o1_id from bk)),
  1::bigint, 'its occurrence is back'
);
select is(
  (select count(*) from public.reservation_events where request_id = (select r1_id from bk)
     and action = 'submitted'),
  1::bigint, 'its event history is back'
);
select is(
  (select count(*) from public.facilities where id = (select f2_id from bk)),
  0::bigint, 'the facility added after the backup is gone'
);
select is(
  (select count(*) from public.reservation_requests where id = (select r2_id from bk)),
  0::bigint, 'the reservation added after the backup is gone'
);

-- Every covered table holds exactly what the backup captured (profiles and the
-- preferences of the deleted account are checked separately below).
select is(
  (select count(*) from jsonb_each_text(
     (select table_counts from public.system_backups
      where id = (select backup_id from bk_runs where name = 'main'))) e
   where e.key not in ('profiles', 'notification_preferences')
     and e.value::bigint <> (xpath('/row/c/text()',
       query_to_xml(format('select count(*) as c from public.%I', e.key), false, true, '')))[1]::text::bigint),
  0::bigint, 'every restored table matches the backup row for row count'
);
select is(
  (select count(*) from public.app_notifications n
   where n.created_at >= (select created_at from public.system_backups
     where id = (select backup_id from bk_runs where name = 'main')) + interval '1 millisecond'),
  0::bigint, 'the restore sent no notifications'
);
select is(
  (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relnamespace = 'public'::regnamespace and not t.tgisinternal and t.tgenabled <> 'O'),
  0::bigint, 'every user trigger is enabled again'
);
select is(
  (select count(*) from public.facilities f
   where not exists (select 1 from public.facility_rating_stats s where s.facility_id = f.id)),
  0::bigint, 'rating stats are rebuilt for every facility'
);

select is(
  (select label from public.organization_account_slots where id = (select slot_id from bk)),
  'Authorized representative', 'the organization slot edit was rolled back'
);
select is(
  (select organization_slot_id from public.profiles where id = (select org_id from bk)),
  (select slot_id from bk), 'the profile-to-organization link is restored'
);
select is(
  (select loyalty_discount_application_id from public.reservation_requests where id = (select r1_id from bk)),
  (select application_id from bk), 'the reservation-to-discount link is restored'
);
select is(
  (select count(*) from public.profiles where id = (select ghost_id from bk)),
  0::bigint, 'an account whose login no longer exists is not resurrected'
);
select is(
  (select count(*) from public.notification_preferences where user_id = (select ghost_id from bk)),
  0::bigint, 'rows that depend on the missing account are dropped'
);
select is(
  (select count(*) from public.profiles where id = (select late_id from bk)),
  1::bigint, 'an account created after the backup is kept'
);
select is(
  (select result -> 'skipped_rows' ->> 'profiles' from bk_runs where name = 'main'),
  '1', 'the result reports the skipped profile'
);
select is(
  (select result -> 'profiles' ->> 'kept_newer' from bk_runs where name = 'main'),
  '1', 'the result reports the profile that was kept'
);
select is(
  (select kind from public.system_backups
   where id = (select (result ->> 'safety_backup_id')::uuid from bk_runs where name = 'main')),
  'pre_restore', 'a safety backup was taken before the restore'
);
select is(
  (select payload -> 'tables' -> 'facilities' @> jsonb_build_array(jsonb_build_object('id', (select f2_id from bk)))
   from public.system_backups
   where id = (select (result ->> 'safety_backup_id')::uuid from bk_runs where name = 'main')),
  true, 'the safety backup holds the pre-restore state'
);
select isnt(
  (select restored_at from public.system_backups
   where id = (select backup_id from bk_runs where name = 'main')),
  null, 'the backup records when it was restored'
);
select is(
  (select count(*) from public.audit_entries
   where entity_type = 'system' and action = 'restored a system backup'
     and reason = 'round trip test'
     and details ->> 'safety_backup_id' = (select result ->> 'safety_backup_id' from bk_runs where name = 'main')),
  1::bigint, 'the restore is written to the audit log with its reason'
);

-- Undo: restoring the safety backup brings the post-change state back.
select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;
select lives_ok(
  $$select public.restore_system_backup(
      (select (result ->> 'safety_backup_id')::uuid from bk_runs where name = 'main'),
      'undo the round trip', 'RESTORE')$$,
  'the safety backup can be restored'
);
reset role;
select is(
  (select count(*) from public.facilities where id = (select f2_id from bk))
  + (select count(*) from public.reservation_requests where id = (select r2_id from bk))
  + (select count(*) from public.facilities where id = (select f1_id from bk) and capacity = 99),
  3::bigint, 'undoing the restore brings the later changes back'
);

-- ---------------------------------------------------------------------
-- Rejections
-- ---------------------------------------------------------------------

select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;
insert into bk_runs (name, backup_id) select 'tamper', id from public.create_system_backup('tamper');
insert into bk_runs (name, backup_id) select 'old', id from public.create_system_backup('old schema');
insert into bk_runs (name, backup_id) select 'lockout', id from public.create_system_backup('lockout');
reset role;

update public.system_backups
set payload = jsonb_set(payload, '{tables,facilities,0,capacity}', '1')
where id = (select backup_id from bk_runs where name = 'tamper');
update public.system_backups set schema_version = '19990101000000', schema_fingerprint = 'stale'
where id = (select backup_id from bk_runs where name = 'old');
update public.system_backups
set payload = jsonb_set(payload, '{tables,profiles}', (
      select jsonb_agg(case when e ->> 'id' = (select ia_id::text from bk)
        then jsonb_set(e, '{role}', '"user"') else e end)
      from jsonb_array_elements(payload -> 'tables' -> 'profiles') e)),
    checksum = ''
where id = (select backup_id from bk_runs where name = 'lockout');
update public.system_backups
set checksum = encode(extensions.digest(payload::text, 'sha256'), 'hex')
where id = (select backup_id from bk_runs where name = 'lockout');

select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;

select throws_ok(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'tamper'), 'tamper', 'RESTORE')$$,
  '22023', 'Backup failed its integrity check', 'a tampered backup is refused'
);
select throws_like(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'old'), 'old', 'RESTORE')$$,
  'This backup was taken on database version 19990101000000%',
  'a backup from another schema version is refused'
);
select throws_like(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'lockout'), 'lockout', 'RESTORE')$$,
  'This backup would remove your own administrator access%',
  'a restore cannot lock out the administrator running it'
);
select throws_ok(
  $$select public.restore_system_backup(gen_random_uuid(), 'missing', 'RESTORE')$$,
  'P0002', 'Backup not found', 'restoring an unknown backup fails'
);

reset role;
select is(
  (select capacity from public.facilities where id = (select f1_id from bk)), 99,
  'rejected restores left the data untouched'
);

-- Imports
select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;

select throws_ok(
  $$select public.import_system_backup('{"format":"other","format_version":1}'::jsonb)$$,
  '22023', 'The file is not a SmartReserve backup', 'a file with the wrong format is refused'
);
select throws_ok(
  $$select public.import_system_backup('{"format":"smartreserve-backup","format_version":2,"schema_version":"1","captured_at":"2026-01-01","tables":{}}'::jsonb)$$,
  '22023', 'Unsupported backup format version', 'an unknown format version is refused'
);
select throws_ok(
  $$select public.import_system_backup('{"format":"smartreserve-backup","format_version":1,"schema_version":"1","captured_at":"2026-01-01","tables":{"pg_authid":[]}}'::jsonb)$$,
  '22023', 'Backup contains unknown table pg_authid', 'a file naming an unknown table is refused'
);
select throws_ok(
  $$select public.import_system_backup('{"format":"smartreserve-backup","format_version":1,"schema_version":"1","captured_at":"2026-01-01","tables":[]}'::jsonb)$$,
  '22023', 'The backup has no table data', 'a file without table data is refused'
);

-- A downloaded backup can be uploaded again and restored.
insert into bk_runs (name, backup_id)
select 'uploaded', id from public.import_system_backup(
  public.get_system_backup_payload((select backup_id from bk_runs where name = 'main')),
  'from file'
);
reset role;
select is(
  (select kind from public.system_backups where id = (select backup_id from bk_runs where name = 'uploaded')),
  'uploaded', 'an imported file is stored as an uploaded backup'
);
select is(
  (select count(*) from public.audit_entries
   where entity_type = 'system' and action = 'downloaded a system backup'),
  1::bigint, 'downloading a backup is audited'
);

reset role;
select set_config('request.jwt.claim.sub', (select ea_id::text from bk), false);
set local role authenticated;
select throws_ok(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'uploaded'), 'external try', 'RESTORE')$$,
  '42501', 'Only an Internal Admin can restore an uploaded backup',
  'an external admin cannot restore an uploaded file'
);

reset role;
select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;
select lives_ok(
  $$select public.restore_system_backup((select backup_id from bk_runs where name = 'uploaded'), 'restore from file', 'RESTORE')$$,
  'an internal admin can restore an uploaded file'
);
reset role;
select is(
  (select capacity from public.facilities where id = (select f1_id from bk)), 40,
  'the uploaded backup restored the original data'
);

-- ---------------------------------------------------------------------
-- Automatic backups and deletion
-- ---------------------------------------------------------------------

create temp table manual_before as select count(*) n from public.system_backups where kind = 'manual';
grant select on manual_before to service_role;

set local role service_role;
select public.run_automatic_system_backup() from generate_series(1, 9);
reset role;

select is(
  (select count(*) from public.system_backups where kind = 'automatic'),
  7::bigint, 'only the newest seven automatic backups are kept'
);
select is(
  (select count(*) from public.system_backups where kind = 'manual'),
  (select n from manual_before), 'automatic pruning never touches manual backups'
);

select set_config('request.jwt.claim.sub', (select ia_id::text from bk), false);
set local role authenticated;
select throws_ok(
  $$select public.delete_system_backup((select (result ->> 'safety_backup_id')::uuid from bk_runs where name = 'main'))$$,
  '40001', 'A safety backup cannot be deleted for 24 hours after it is created',
  'a fresh safety backup cannot be deleted'
);
select lives_ok(
  $$select public.delete_system_backup((select backup_id from bk_runs where name = 'tamper'), 'cleanup')$$,
  'a manual backup can be deleted'
);
select is(
  (select count(*) from public.list_system_backups() where id = (select backup_id from bk_runs where name = 'tamper')),
  0::bigint, 'a deleted backup is no longer listed'
);
reset role;
select is(
  (select count(*) from public.audit_entries
   where entity_type = 'system' and action = 'deleted a system backup' and reason = 'cleanup'),
  1::bigint, 'deleting a backup is audited'
);

select * from finish();
rollback;
