-- Email notification delivery (Gmail SMTP).
--
-- Every app_notifications insert now also enqueues an email_deliveries
-- outbox row, alongside the push_deliveries row. A pg_cron sweep plus an
-- immediate pg_net nudge drive the send-email edge function, which leases
-- rows, sends them through SMTP and reports back. Same shape as the push
-- outbox (20260927100000_push_notification_delivery.sql).
--
-- Users opt out with notification_preferences.email_notifications. The
-- per-kind toggles (day-before reminders, new facilities) apply to email
-- exactly as they do to push.

alter table public.notification_preferences
  add column if not exists email_notifications boolean not null default true;

create table if not exists public.email_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null
    references public.app_notifications(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending','processing','sent','failed','skipped')),
  attempt_count integer not null default 0 check (attempt_count between 0 and 20),
  next_attempt_at timestamptz,
  locked_at timestamptz,
  last_error_code text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  constraint email_deliveries_one_per_notification unique (notification_id)
);
create index if not exists email_deliveries_pending_due_idx
  on public.email_deliveries(next_attempt_at, created_at)
  where status = 'pending';
create index if not exists email_deliveries_processing_stale_idx
  on public.email_deliveries(locked_at)
  where status = 'processing';

alter table public.email_deliveries enable row level security;
revoke all on public.email_deliveries from public, anon, authenticated;
grant select, insert, update on public.email_deliveries to service_role;

-- A recipient gets email only with a usable address, an active account, the
-- email toggle on, and the per-kind toggle (shared with push) allowing it.
create or replace function public.email_delivery_allowed(p_recipient uuid, p_kind text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select profile.account_status = 'active'
      and position('@' in coalesce(profile.email, '')) > 1
    from public.profiles as profile
    where profile.id = p_recipient
  ), false)
  and coalesce((
    select preference.email_notifications
    from public.notification_preferences as preference
    where preference.user_id = p_recipient
  ), true)
  and public.push_kind_allowed(p_recipient, p_kind);
$$;

revoke all on function public.email_delivery_allowed(uuid, text) from public, anon, authenticated;
grant execute on function public.email_delivery_allowed(uuid, text) to service_role;

-- Best-effort nudge: wakes the email worker immediately instead of waiting
-- for the next cron tick. A missing pg_net/vault secret must never fail the
-- caller, so every failure mode here is swallowed.
create or replace function public.invoke_email_dispatch_worker()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  function_base_url text;
  worker_key text;
  request_id bigint;
begin
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
      using 'smartreserve_function_url'
      into function_base_url;
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1'
      using 'smartreserve_email_worker_key'
      into worker_key;
  exception
    when invalid_schema_name or undefined_table or undefined_function then
      return null;
  end;

  if nullif(trim(coalesce(function_base_url, '')), '') is null
     or nullif(trim(coalesce(worker_key, '')), '') is null then
    return null;
  end if;

  begin
    execute
      'select net.http_post(url := $1, headers := $2, body := $3)'
      using
        trim(trailing '/' from function_base_url) || '/functions/v1/send-email',
        jsonb_build_object(
          'Content-Type', 'application/json',
          'x-smartreserve-worker-key', worker_key
        ),
        jsonb_build_object('source', 'trigger_nudge', 'scheduled_at', now())
      into request_id;
  exception
    when invalid_schema_name or undefined_function then
      return null;
  end;

  return request_id;
exception
  when others then
    return null;
end;
$$;

revoke all on function public.invoke_email_dispatch_worker() from public, anon, authenticated;
grant execute on function public.invoke_email_dispatch_worker() to service_role;

create or replace function public.enqueue_email_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  allowed boolean;
begin
  begin
    allowed := public.email_delivery_allowed(new.recipient_id, new.kind);

    insert into public.email_deliveries(
      notification_id, recipient_id, status, next_attempt_at
    )
    values (
      new.id,
      new.recipient_id,
      case when allowed then 'pending' else 'skipped' end,
      case when allowed then now() else null end
    )
    on conflict (notification_id) do nothing;

    if allowed then
      perform public.invoke_email_dispatch_worker();
    end if;
  exception
    when others then
      return new;
  end;

  return new;
end;
$$;

revoke all on function public.enqueue_email_delivery() from public, anon, authenticated;

drop trigger if exists app_notifications_enqueue_email on public.app_notifications;
create trigger app_notifications_enqueue_email
after insert on public.app_notifications
for each row execute procedure public.enqueue_email_delivery();

-- Leases due deliveries for the send-email worker. Recipients who opted out
-- (or lost their address) after the row was queued are skipped first, so
-- the worker never sees them. Returns each delivery joined to its
-- notification content and the recipient's address and name.
create or replace function public.lease_email_deliveries(
  p_limit integer default 20,
  p_lease_seconds integer default 120,
  p_max_attempts integer default 5
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bounded_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
  lease interval := make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120)));
  result_value jsonb;
begin
  if coalesce(p_max_attempts, 5) < 1 then
    raise exception using errcode = '22023', message = 'Invalid max attempts';
  end if;

  update public.email_deliveries
  set status = 'failed',
      last_error_code = 'stale_processing',
      next_attempt_at = null,
      locked_at = null
  where status = 'processing'
    and coalesce(locked_at, created_at) < now() - lease
    and attempt_count >= coalesce(p_max_attempts, 5);

  update public.email_deliveries d
  set status = 'skipped',
      last_error_code = 'not_allowed',
      next_attempt_at = null,
      locked_at = null
  from public.app_notifications n
  where n.id = d.notification_id
    and (
      d.status = 'pending'
      or (d.status = 'processing' and coalesce(d.locked_at, d.created_at) < now() - lease)
    )
    and not public.email_delivery_allowed(d.recipient_id, n.kind);

  with candidates as (
    select d.id
    from public.email_deliveries d
    where d.attempt_count < coalesce(p_max_attempts, 5)
      and (
        (d.status = 'pending' and coalesce(d.next_attempt_at, d.created_at) <= now())
        or
        (d.status = 'processing' and coalesce(d.locked_at, d.created_at) < now() - lease)
      )
    order by coalesce(d.next_attempt_at, d.created_at), d.created_at
    for update of d skip locked
    limit bounded_limit
  ),
  claimed as (
    update public.email_deliveries d
    set status = 'processing',
        locked_at = now(),
        next_attempt_at = null,
        last_error_code = null,
        attempt_count = d.attempt_count + 1
    from candidates c
    where d.id = c.id
    returning d.*
  )
  select jsonb_build_object(
    'rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id,
      'notification_id', c.notification_id,
      'recipient_id', c.recipient_id,
      'attempt_count', c.attempt_count,
      'kind', n.kind,
      'title', n.title,
      'body', n.body,
      'request_id', n.request_id,
      'created_at', n.created_at,
      'email', p.email,
      'full_name', p.full_name
    ) order by c.created_at), '[]'::jsonb)
  )
  into result_value
  from claimed c
  join public.app_notifications n on n.id = c.notification_id
  join public.profiles p on p.id = c.recipient_id;

  return coalesce(result_value, jsonb_build_object('rows', '[]'::jsonb));
end;
$$;

revoke all on function public.lease_email_deliveries(integer, integer, integer)
from public, anon, authenticated;
grant execute on function public.lease_email_deliveries(integer, integer, integer)
to service_role;

-- Finalizes a leased delivery. A retryable failure backs off exponentially
-- (1, 2, 4 … 30 minutes); a permanent one (p_permanent, e.g. a rejected
-- address) fails immediately.
create or replace function public.complete_email_delivery(
  p_id uuid,
  p_status text,
  p_error_code text default null,
  p_permanent boolean default false,
  p_max_attempts integer default 5
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  attempt_value integer;
  retry_seconds integer;
begin
  if p_status not in ('sent','failed') then
    raise exception using errcode = '22023', message = 'Invalid delivery status';
  end if;

  select attempt_count into attempt_value
  from public.email_deliveries
  where id = p_id and status = 'processing'
  for update;

  if not found then
    return;
  end if;

  if p_status = 'sent' then
    update public.email_deliveries
    set status = 'sent',
        sent_at = now(),
        last_error_code = null,
        next_attempt_at = null,
        locked_at = null
    where id = p_id;
    return;
  end if;

  if coalesce(p_permanent, false) or attempt_value >= coalesce(p_max_attempts, 5) then
    update public.email_deliveries
    set status = 'failed',
        last_error_code = left(coalesce(p_error_code, 'send_failed'), 80),
        next_attempt_at = null,
        locked_at = null
    where id = p_id;
    return;
  end if;

  retry_seconds := least((60 * power(2, greatest(attempt_value - 1, 0)))::integer, 1800);
  update public.email_deliveries
  set status = 'pending',
      last_error_code = left(coalesce(p_error_code, 'send_failed'), 80),
      next_attempt_at = now() + make_interval(secs => retry_seconds),
      locked_at = null
  where id = p_id;
end;
$$;

revoke all on function public.complete_email_delivery(uuid, text, text, boolean, integer)
from public, anon, authenticated;
grant execute on function public.complete_email_delivery(uuid, text, text, boolean, integer)
to service_role;

-- Delivery state is not restored from a backup, like push_deliveries.
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
    'email_deliveries',
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

revoke all on function public.system_backup_excluded_tables() from public, anon, authenticated;
grant execute on function public.system_backup_excluded_tables() to service_role;

do $$
begin
  begin
    if exists (select 1 from pg_namespace where nspname = 'cron') then
      if not exists (
        select 1 from cron.job where jobname = 'smartreserve-email-dispatch'
      ) then
        perform cron.schedule(
          'smartreserve-email-dispatch',
          '* * * * *',
          'select public.invoke_email_dispatch_worker();'
        );
      end if;
    end if;
  exception
    when invalid_schema_name or undefined_table or undefined_function
      or insufficient_privilege then
      raise notice 'email dispatch cron scheduling was skipped; configure pg_cron manually before enabling the worker.';
  end;
end $$;

notify pgrst, 'reload schema';
