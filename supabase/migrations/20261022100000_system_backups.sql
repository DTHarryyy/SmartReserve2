-- Backup & recovery: point-in-time snapshots of the operational records, a
-- transactional restore with an automatic safety snapshot, and a nightly
-- automatic backup. Storage objects are not copied; the rows holding their
-- paths are. auth.users is never touched.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.system_backups (
  id uuid primary key default gen_random_uuid(),
  label text not null default '' check (length(label) <= 120),
  kind text not null check (kind in ('manual', 'automatic', 'pre_restore', 'uploaded')),
  format_version integer not null default 1,
  schema_version text not null,
  table_counts jsonb not null default '{}'::jsonb,
  size_bytes bigint not null,
  checksum text not null,
  payload jsonb not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_by_name text not null,
  created_at timestamptz not null default now(),
  restored_at timestamptz,
  restored_by uuid references public.profiles(id) on delete set null,
  restored_by_name text,
  schema_fingerprint text
);

create index if not exists system_backups_created_idx
  on public.system_backups(created_at desc);
create index if not exists system_backups_kind_idx
  on public.system_backups(kind, created_at desc);

-- No direct client access: every read goes through the RPCs below so the
-- payload is never exposed by a PostgREST select *.
alter table public.system_backups enable row level security;
revoke all on public.system_backups from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Coverage lists. Restore order: parents before children.
-- ---------------------------------------------------------------------

create or replace function public.system_backup_tables()
returns text[]
language sql
immutable
set search_path = public
as $$
  select array[
    'profiles',
    'institution_settings',
    'organizational_units',
    'organization_account_slots',
    'campus_map_features',
    'facilities',
    'terms_versions',
    'facility_rates',
    'facility_amenities',
    'facility_payment_methods',
    'facility_location_reviews',
    'loyalty_point_rules',
    'loyalty_rewards',
    'loyalty_discount_offers',
    'anomaly_rules',
    'ceo_signature_revisions',
    'permit_official_signature_revisions',
    'verification_submissions',
    'account_admin_events',
    'notification_preferences',
    'reservation_requests',
    'reservation_occurrences',
    'reservation_amenities',
    'reservation_price_lines',
    'reservation_terms_acceptances',
    'reservation_attachments',
    'reservation_events',
    'reservation_payment_reminders',
    'payment_transactions',
    'reservation_signature_requests',
    'reservation_user_signatures',
    'reservation_permits',
    'reservation_permit_items',
    'reservation_use_assessments',
    'reservation_use_assessment_files',
    'reservation_time_charges',
    'reservation_feedback',
    'reservation_feedback_replies',
    'feedback_sentiment_analyses',
    'loyalty_transactions',
    'loyalty_redemptions',
    'loyalty_discount_claims',
    'loyalty_discount_applications',
    'reservation_anomalies',
    'reservation_anomaly_evidence',
    'app_notifications'
  ]::text[];
$$;

-- Nullable FK columns that close a dependency cycle. They are loaded as NULL
-- and patched in once every table is back.
create or replace function public.system_backup_deferred_columns()
returns table(table_name text, column_name text)
language sql
immutable
set search_path = public
as $$
  select * from (values
    ('profiles'::text, 'organization_slot_id'::text),
    ('reservation_requests'::text, 'loyalty_discount_application_id'::text)
  ) as v(table_name, column_name);
$$;

create or replace function public.system_backup_excluded_tables()
returns text[]
language sql
immutable
set search_path = public
as $$
  select array[
    -- Append-only history: never rolled back; restores add entries to it.
    'audit_entries',
    -- The backups themselves.
    'system_backups',
    -- Undo tokens: cleared on restore so a stale undo cannot replay.
    'reservation_action_journal',
    -- Derived data: rebuilt after a restore.
    'facility_rating_stats',
    'facility_anomaly_baselines',
    'renter_risk_profiles',
    -- Delivery state and device tokens.
    'push_deliveries',
    'user_push_tokens',
    -- Assistant chat state, telemetry and seed knowledge.
    'assistant_conversations',
    'assistant_messages',
    'assistant_knowledge_base',
    'assistant_llm_requests',
    'assistant_rate_limits',
    'assistant_response_cache',
    -- Work queues.
    'reservation_anomaly_evaluation_queue',
    'reservation_anomaly_backfill_runs',
    -- Retired legacy tables.
    'facility_admin_assignments',
    'facility_admin_assignment_archive'
  ]::text[];
$$;

revoke all on function public.system_backup_tables() from public, anon, authenticated;
revoke all on function public.system_backup_deferred_columns() from public, anon, authenticated;
revoke all on function public.system_backup_excluded_tables() from public, anon, authenticated;
grant execute on function public.system_backup_tables() to authenticated, service_role;
grant execute on function public.system_backup_deferred_columns() to service_role;
grant execute on function public.system_backup_excluded_tables() to service_role;

-- ---------------------------------------------------------------------
-- Summary type returned to clients (never carries the payload)
-- ---------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'system_backup_summary'
  ) then
    create type public.system_backup_summary as (
      id uuid,
      label text,
      kind text,
      format_version integer,
      schema_version text,
      table_counts jsonb,
      size_bytes bigint,
      checksum text,
      created_by_name text,
      created_at timestamptz,
      restored_at timestamptz,
      restored_by_name text,
      schema_compatible boolean
    );
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------

create or replace function public._system_backup_schema_version()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    return 'unknown';
  end if;
  execute 'select max(version) from supabase_migrations.schema_migrations' into v;
  return coalesce(v, 'unknown');
end;
$$;

-- Hash of the column layout of every backed-up table. A backup can be restored
-- whenever this still matches, so migrations that do not touch those tables
-- (functions, policies, other tables) do not strand existing backups.
create or replace function public._system_backup_schema_fingerprint()
returns text
language sql
stable
set search_path = public, extensions
as $$
  select encode(extensions.digest(coalesce(string_agg(
    t.name || '.' || a.attname || ':' || format_type(a.atttypid, a.atttypmod)
      || ':' || a.attnotnull::text,
    ',' order by t.ord, a.attname
  ), ''), 'sha256'), 'hex')
  from unnest(public.system_backup_tables()) with ordinality as t(name, ord)
  join pg_attribute a
    on a.attrelid = format('public.%I', t.name)::regclass
   and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
$$;

create or replace function public._system_backup_actor()
returns table(id uuid, name text, role text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, coalesce(nullif(p.full_name, ''), p.email), p.role
  from public.profiles p
  where p.id = auth.uid()
  union all
  select null::uuid, 'System', 'system'
  where not exists (select 1 from public.profiles q where q.id = auth.uid())
  limit 1;
$$;

create or replace function public._system_backup_summary(b public.system_backups)
returns public.system_backup_summary
language sql
stable
set search_path = public
as $$
  select row(
    b.id, b.label, b.kind, b.format_version, b.schema_version, b.table_counts,
    b.size_bytes, b.checksum, b.created_by_name, b.created_at, b.restored_at,
    b.restored_by_name,
    coalesce(b.schema_fingerprint = public._system_backup_schema_fingerprint(), false)
  )::public.system_backup_summary;
$$;

create or replace function public._system_backup_audit(
  p_action text,
  p_label text,
  p_backup_id uuid,
  p_details jsonb default '{}'::jsonb,
  p_material boolean default true,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor record;
begin
  select * into actor from public._system_backup_actor();
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, details, material
  ) values (
    'system', p_backup_id,
    'System backup — ' || coalesce(nullif(p_label, ''), 'unlabelled'),
    actor.id, actor.name, actor.role, p_action, p_reason, p_details, p_material
  );
end;
$$;

create or replace function public._capture_system_backup(
  p_label text,
  p_kind text,
  p_actor_id uuid,
  p_actor_name text
) returns public.system_backups
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t text;
  table_rows jsonb;
  tables jsonb := '{}'::jsonb;
  counts jsonb := '{}'::jsonb;
  body jsonb;
  body_text text;
  result public.system_backups;
begin
  foreach t in array public.system_backup_tables() loop
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x',
      t
    ) into table_rows;
    tables := tables || jsonb_build_object(t, table_rows);
    counts := counts || jsonb_build_object(t, jsonb_array_length(table_rows));
  end loop;

  body := jsonb_build_object(
    'format', 'smartreserve-backup',
    'format_version', 1,
    'schema_version', public._system_backup_schema_version(),
    'schema_fingerprint', public._system_backup_schema_fingerprint(),
    'captured_at', now(),
    'tables', tables
  );

  body_text := body::text;
  insert into public.system_backups(
    label, kind, format_version, schema_version, table_counts, size_bytes,
    checksum, payload, created_by, created_by_name, schema_fingerprint
  ) values (
    left(coalesce(p_label, ''), 120), p_kind, 1, body ->> 'schema_version', counts,
    octet_length(body_text),
    encode(extensions.digest(body_text, 'sha256'), 'hex'),
    body, p_actor_id, p_actor_name, body ->> 'schema_fingerprint'
  ) returning * into result;
  return result;
end;
$$;

-- Generic loader. Mirrors what Postgres would have done had a referenced
-- row vanished: set-null references are nulled, cascade/restrict children
-- are dropped. Returns the number of rows inserted.
create or replace function public._restore_system_table(p_table text, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  rel regclass := format('public.%I', p_table)::regclass;
  col record;
  fk record;
  col_list text := '';
  sel_list text := '';
  cond text := 'true';
  inserted integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return 0;
  end if;

  for col in
    select a.attname::text as name,
      exists (
        select 1 from public.system_backup_deferred_columns() d
        where d.table_name = p_table and d.column_name = a.attname::text
      ) as deferred
    from pg_attribute a
    where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
    order by a.attnum
  loop
    col_list := col_list || case when col_list = '' then '' else ', ' end || quote_ident(col.name);

    select c.confrelid::regclass::text as parent, pa.attname::text as parent_col, c.confdeltype
    into fk
    from pg_constraint c
    join pg_attribute ca on ca.attrelid = c.conrelid and ca.attname = col.name
    join pg_attribute pa on pa.attrelid = c.confrelid and pa.attnum = c.confkey[1]
    where c.conrelid = rel and c.contype = 'f'
      and array_length(c.conkey, 1) = 1 and c.conkey[1] = ca.attnum
      and c.confrelid <> c.conrelid
    limit 1;

    if col.deferred then
      sel_list := sel_list || case when sel_list = '' then '' else ', ' end || 'null';
    elsif fk.parent is not null and fk.confdeltype in ('n', 'd') then
      sel_list := sel_list || case when sel_list = '' then '' else ', ' end || format(
        'case when r.%1$I is null or exists (select 1 from %2$s p where p.%3$I = r.%1$I) then r.%1$I end',
        col.name, fk.parent, fk.parent_col
      );
    else
      sel_list := sel_list || case when sel_list = '' then '' else ', ' end || format('r.%I', col.name);
      if fk.parent is not null then
        cond := cond || format(
          ' and (r.%1$I is null or exists (select 1 from %2$s p where p.%3$I = r.%1$I))',
          col.name, fk.parent, fk.parent_col
        );
      end if;
    end if;
    fk := null;
  end loop;

  execute format(
    'insert into public.%1$I (%2$s) select %3$s from jsonb_populate_recordset(null::public.%1$I, $1) r where %4$s',
    p_table, col_list, sel_list, cond
  ) using p_rows;
  get diagnostics inserted = row_count;
  return inserted;
end;
$$;

-- Profiles are upserted, never deleted: their identity lives in auth.users,
-- which a restore does not touch.
create or replace function public._restore_system_profiles(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  col_list text;
  sel_list text;
  set_list text;
  upserted integer := 0;
  total integer := coalesce(jsonb_array_length(p_rows), 0);
  skipped integer;
  kept_newer integer;
begin
  select
    string_agg(quote_ident(a.attname), ', ' order by a.attnum),
    string_agg(
      case when a.attname = 'organization_slot_id' then 'null' else 'r.' || quote_ident(a.attname) end,
      ', ' order by a.attnum
    ),
    string_agg(
      quote_ident(a.attname) || ' = excluded.' || quote_ident(a.attname), ', ' order by a.attnum
    ) filter (where a.attname <> 'id')
  into col_list, sel_list, set_list
  from pg_attribute a
  where a.attrelid = 'public.profiles'::regclass and a.attnum > 0
    and not a.attisdropped and a.attgenerated = '';

  if total > 0 then
    execute format(
      'insert into public.profiles (%1$s) select %2$s from jsonb_populate_recordset(null::public.profiles, $1) r
       where exists (select 1 from auth.users u where u.id = r.id)
       on conflict (id) do update set %3$s',
      col_list, sel_list, set_list
    ) using p_rows;
    get diagnostics upserted = row_count;
  end if;

  select count(*) into kept_newer
  from public.profiles p
  where not exists (
    select 1 from jsonb_populate_recordset(null::public.profiles, coalesce(p_rows, '[]'::jsonb)) r
    where r.id = p.id
  );

  skipped := total - upserted;
  return jsonb_build_object(
    'upserted', upserted,
    'skipped_missing_auth', skipped,
    'kept_newer', kept_newer
  );
end;
$$;

revoke all on function public._system_backup_schema_version() from public, anon, authenticated;
revoke all on function public._system_backup_schema_fingerprint() from public, anon, authenticated;
revoke all on function public._system_backup_actor() from public, anon, authenticated;
revoke all on function public._system_backup_summary(public.system_backups) from public, anon, authenticated;
revoke all on function public._system_backup_audit(text, text, uuid, jsonb, boolean, text) from public, anon, authenticated;
revoke all on function public._capture_system_backup(text, text, uuid, text) from public, anon, authenticated;
revoke all on function public._restore_system_table(text, jsonb) from public, anon, authenticated;
revoke all on function public._restore_system_profiles(jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Client RPCs
-- ---------------------------------------------------------------------

create or replace function public.list_system_backups()
returns setof public.system_backup_summary
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  return query
    select (public._system_backup_summary(b)).*
    from public.system_backups b
    order by b.created_at desc, b.id desc;
end;
$$;

create or replace function public.create_system_backup(p_label text default '')
returns public.system_backup_summary
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  actor record;
  label text := trim(coalesce(p_label, ''));
  b public.system_backups;
begin
  if not public.is_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if length(label) > 120 then
    raise exception using errcode = '22023', message = 'The label must be 120 characters or fewer';
  end if;
  select * into actor from public._system_backup_actor();
  b := public._capture_system_backup(label, 'manual', actor.id, actor.name);
  perform public._system_backup_audit(
    'created a system backup', b.label, b.id,
    jsonb_build_object('table_counts', b.table_counts, 'size_bytes', b.size_bytes)
  );
  return public._system_backup_summary(b);
end;
$$;

create or replace function public.get_system_backup_payload(p_backup_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.system_backups;
begin
  if not public.is_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  select * into b from public.system_backups where id = p_backup_id;
  if b.id is null then
    raise exception using errcode = 'P0002', message = 'Backup not found';
  end if;
  perform public._system_backup_audit(
    'downloaded a system backup', b.label, b.id, '{}'::jsonb, false
  );
  return b.payload;
end;
$$;

-- Uploaded files are untrusted: a crafted file could promote accounts when
-- restored, so only Internal Admins may import one.
create or replace function public.import_system_backup(
  p_payload jsonb,
  p_label text default ''
) returns public.system_backup_summary
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  actor record;
  label text := trim(coalesce(p_label, ''));
  unknown_table text;
  counts jsonb;
  b public.system_backups;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if length(label) > 120 then
    raise exception using errcode = '22023', message = 'The label must be 120 characters or fewer';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'The file is not a SmartReserve backup';
  end if;
  if p_payload ->> 'format' is distinct from 'smartreserve-backup' then
    raise exception using errcode = '22023', message = 'The file is not a SmartReserve backup';
  end if;
  if p_payload ->> 'format_version' is distinct from '1' then
    raise exception using errcode = '22023', message = 'Unsupported backup format version';
  end if;
  if coalesce(p_payload ->> 'schema_version', '') = '' or coalesce(p_payload ->> 'captured_at', '') = '' then
    raise exception using errcode = '22023', message = 'The backup is missing its schema version or capture time';
  end if;
  if jsonb_typeof(p_payload -> 'tables') is distinct from 'object' then
    raise exception using errcode = '22023', message = 'The backup has no table data';
  end if;
  select k into unknown_table
  from jsonb_object_keys(p_payload -> 'tables') k
  where k <> all (public.system_backup_tables())
  limit 1;
  if unknown_table is not null then
    raise exception using errcode = '22023', message = format('Backup contains unknown table %s', unknown_table);
  end if;
  if exists (
    select 1 from jsonb_each(p_payload -> 'tables') e
    where jsonb_typeof(e.value) <> 'array'
  ) then
    raise exception using errcode = '22023', message = 'Backup table data must be lists of rows';
  end if;
  if exists (
    select 1 from jsonb_each(p_payload -> 'tables') e,
      jsonb_array_elements(e.value) el
    where jsonb_typeof(el) <> 'object'
  ) then
    raise exception using errcode = '22023', message = 'Backup rows must be objects';
  end if;
  if octet_length(p_payload::text) > 50 * 1024 * 1024 then
    raise exception using errcode = '22023', message = 'The backup file is larger than 50 MB';
  end if;

  select coalesce(jsonb_object_agg(e.key, jsonb_array_length(e.value)), '{}'::jsonb)
  into counts
  from jsonb_each(p_payload -> 'tables') e;

  select * into actor from public._system_backup_actor();
  insert into public.system_backups(
    label, kind, format_version, schema_version, table_counts, size_bytes,
    checksum, payload, created_by, created_by_name, schema_fingerprint
  ) values (
    case when label = '' then 'Uploaded backup' else label end, 'uploaded', 1,
    p_payload ->> 'schema_version', counts, octet_length(p_payload::text),
    encode(extensions.digest(p_payload::text, 'sha256'), 'hex'),
    p_payload, actor.id, actor.name, p_payload ->> 'schema_fingerprint'
  ) returning * into b;

  perform public._system_backup_audit(
    'imported a system backup', b.label, b.id,
    jsonb_build_object('table_counts', b.table_counts, 'size_bytes', b.size_bytes)
  );
  return public._system_backup_summary(b);
end;
$$;

create or replace function public.delete_system_backup(
  p_backup_id uuid,
  p_reason text default ''
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.system_backups;
begin
  if not public.is_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  select * into b from public.system_backups where id = p_backup_id for update;
  if b.id is null then
    raise exception using errcode = 'P0002', message = 'Backup not found';
  end if;
  if b.kind = 'pre_restore' and b.created_at > now() - interval '24 hours' then
    raise exception using errcode = '40001',
      message = 'A safety backup cannot be deleted for 24 hours after it is created';
  end if;
  delete from public.system_backups where id = b.id;
  perform public._system_backup_audit(
    'deleted a system backup', b.label, b.id,
    jsonb_build_object('kind', b.kind, 'created_at', b.created_at),
    true, nullif(trim(coalesce(p_reason, '')), '')
  );
end;
$$;

create or replace function public.restore_system_backup(
  p_backup_id uuid,
  p_reason text,
  p_confirm text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  started timestamptz := clock_timestamp();
  actor record;
  b public.system_backups;
  safety public.system_backups;
  v_schema text := public._system_backup_schema_version();
  t text;
  tables text[] := public.system_backup_tables();
  rows_for_table jsonb;
  expected integer;
  inserted integer;
  restored jsonb := '{}'::jsonb;
  skipped jsonb := '{}'::jsonb;
  profiles_result jsonb;
  actor_ok boolean;
begin
  if not public.is_admin() then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception using errcode = '22023', message = 'A reason is required';
  end if;
  if p_confirm is distinct from 'RESTORE' then
    raise exception using errcode = '22023', message = 'Type RESTORE to confirm';
  end if;
  if not pg_try_advisory_xact_lock(hashtext('smartreserve.system_restore')) then
    raise exception using errcode = '55P03', message = 'Another restore is in progress';
  end if;

  select * into b from public.system_backups where id = p_backup_id;
  if b.id is null then
    raise exception using errcode = 'P0002', message = 'Backup not found';
  end if;
  if b.kind = 'uploaded' and not public.is_internal_admin() then
    raise exception using errcode = '42501',
      message = 'Only an Internal Admin can restore an uploaded backup';
  end if;
  if encode(extensions.digest(b.payload::text, 'sha256'), 'hex') <> b.checksum then
    raise exception using errcode = '22023', message = 'Backup failed its integrity check';
  end if;
  if b.format_version <> 1 or b.payload ->> 'format_version' <> '1' then
    raise exception using errcode = '22023', message = 'Unsupported backup format';
  end if;
  if b.schema_fingerprint is distinct from public._system_backup_schema_fingerprint() then
    raise exception using errcode = '22023', message = format(
      'This backup was taken on database version %s and the database structure has changed since (current version %s), so it can no longer be restored.',
      b.schema_version, v_schema
    );
  end if;

  -- Never let a restore lock out the person running it.
  select exists (
    select 1
    from jsonb_populate_recordset(null::public.profiles, b.payload -> 'tables' -> 'profiles') r
    where r.id = auth.uid() and r.role in ('internal_admin', 'external_admin')
      and r.account_status = 'active'
  ) into actor_ok;
  if not actor_ok then
    raise exception using errcode = '22023',
      message = 'This backup would remove your own administrator access, so it cannot be restored by you';
  end if;

  select * into actor from public._system_backup_actor();
  safety := public._capture_system_backup(
    'Before restoring ' || coalesce(nullif(b.label, ''), b.kind || ' backup'),
    'pre_restore', actor.id, actor.name
  );

  -- Keep audit, notification, anomaly, push and rating triggers from firing
  -- while rows are reloaded. FK and CHECK constraints stay enforced.
  foreach t in array tables loop
    execute format('alter table public.%I disable trigger user', t);
  end loop;

  -- Deleting reservations nulls assistant_messages.reservation_id, which would
  -- trip the owner check in validate_assistant_message for the restoring admin.
  alter table public.assistant_messages disable trigger user;

  update public.organizational_units set parent_id = null where parent_id is not null;
  update public.profiles set organization_slot_id = null where organization_slot_id is not null;

  for i in reverse array_length(tables, 1) .. 1 loop
    t := tables[i];
    continue when t = 'profiles';
    -- "where true": safeupdate rejects a bare DELETE.
    execute format('delete from public.%I where true', t);
  end loop;
  delete from public.reservation_action_journal where true;

  profiles_result := public._restore_system_profiles(b.payload -> 'tables' -> 'profiles');
  restored := restored || jsonb_build_object(
    'profiles', (profiles_result ->> 'upserted')::integer
  );
  if (profiles_result ->> 'skipped_missing_auth')::integer > 0 then
    skipped := skipped || jsonb_build_object(
      'profiles', (profiles_result ->> 'skipped_missing_auth')::integer
    );
  end if;

  foreach t in array tables loop
    continue when t = 'profiles';
    rows_for_table := coalesce(b.payload -> 'tables' -> t, '[]'::jsonb);
    expected := jsonb_array_length(rows_for_table);
    inserted := public._restore_system_table(t, rows_for_table);
    restored := restored || jsonb_build_object(t, inserted);
    if expected > inserted then
      skipped := skipped || jsonb_build_object(t, expected - inserted);
    end if;
  end loop;

  -- Deferred cycle columns, only where the referenced row is back.
  update public.profiles p
  set organization_slot_id = r.organization_slot_id
  from jsonb_populate_recordset(null::public.profiles, b.payload -> 'tables' -> 'profiles') r
  where p.id = r.id and r.organization_slot_id is not null
    and exists (select 1 from public.organization_account_slots s where s.id = r.organization_slot_id);

  update public.reservation_requests q
  set loyalty_discount_application_id = r.loyalty_discount_application_id
  from jsonb_populate_recordset(
    null::public.reservation_requests, b.payload -> 'tables' -> 'reservation_requests'
  ) r
  where q.id = r.id and r.loyalty_discount_application_id is not null
    and exists (
      select 1 from public.loyalty_discount_applications a
      where a.id = r.loyalty_discount_application_id
    );

  foreach t in array tables loop
    execute format('alter table public.%I enable trigger user', t);
  end loop;

  alter table public.assistant_messages enable trigger user;

  -- Rebuild derived data that the restore invalidated.
  insert into public.facility_rating_stats(facility_id, rating_average, rating_count, updated_at)
  select f.id, round(avg(fb.rating)::numeric, 2), count(fb.id), now()
  from public.facilities f
  left join public.reservation_feedback fb on fb.facility_id = f.id
  group by f.id
  on conflict (facility_id) do update set
    rating_average = excluded.rating_average,
    rating_count = excluded.rating_count,
    updated_at = excluded.updated_at;

  perform public.refresh_facility_anomaly_baselines(null, now());
  perform public.recalculate_renter_risk_profiles(x.renter_id, x.admin_lane, now())
  from (
    select distinct renter_id, admin_lane from public.reservation_anomalies
  ) x;

  update public.system_backups
  set restored_at = now(), restored_by = actor.id, restored_by_name = actor.name
  where id = b.id;

  perform public._system_backup_audit(
    'restored a system backup', b.label, b.id,
    jsonb_build_object(
      'restored_counts', restored,
      'skipped_rows', skipped,
      'profiles', profiles_result,
      'safety_backup_id', safety.id
    ),
    true, trim(p_reason)
  );

  return jsonb_build_object(
    'backup_id', b.id,
    'safety_backup_id', safety.id,
    'restored_counts', restored,
    'skipped_rows', skipped,
    'profiles', profiles_result,
    'duration_ms', round(extract(epoch from clock_timestamp() - started) * 1000)::integer
  );
end;
$$;

create or replace function public.run_automatic_system_backup()
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  b public.system_backups;
begin
  b := public._capture_system_backup('Nightly backup', 'automatic', null, 'System (nightly)');
  delete from public.system_backups
  where kind = 'automatic'
    and id not in (
      select id from public.system_backups
      where kind = 'automatic'
      order by created_at desc, id desc
      limit 7
    );
  perform public._system_backup_audit(
    'created an automatic system backup', b.label, b.id,
    jsonb_build_object('table_counts', b.table_counts, 'size_bytes', b.size_bytes),
    false
  );
  return b.id;
end;
$$;

revoke all on function public.list_system_backups() from public, anon, authenticated;
revoke all on function public.create_system_backup(text) from public, anon, authenticated;
revoke all on function public.get_system_backup_payload(uuid) from public, anon, authenticated;
revoke all on function public.import_system_backup(jsonb, text) from public, anon, authenticated;
revoke all on function public.delete_system_backup(uuid, text) from public, anon, authenticated;
revoke all on function public.restore_system_backup(uuid, text, text) from public, anon, authenticated;
revoke all on function public.run_automatic_system_backup() from public, anon, authenticated;
grant execute on function public.list_system_backups() to authenticated;
grant execute on function public.create_system_backup(text) to authenticated;
grant execute on function public.get_system_backup_payload(uuid) to authenticated;
grant execute on function public.import_system_backup(jsonb, text) to authenticated;
grant execute on function public.delete_system_backup(uuid, text) to authenticated;
grant execute on function public.restore_system_backup(uuid, text, text) to authenticated;
grant execute on function public.run_automatic_system_backup() to service_role;

create extension if not exists pg_cron;
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'smartreserve-nightly-backup') then
    perform cron.schedule(
      'smartreserve-nightly-backup', '15 18 * * *',
      'select public.run_automatic_system_backup();'
    );
  end if;
end $$;

notify pgrst, 'reload schema';
