-- Push notification delivery (FCM, web + android).
--
-- Layers a device-push transport on top of the existing app_notifications
-- feed. Every app_notifications insert enqueues a push_deliveries outbox row
-- via trigger; a pg_cron sweep plus an immediate pg_net nudge drive the
-- send-push edge function, which leases rows, calls FCM, and reports back.
-- Modeled directly on the feedback-sentiment outbox
-- (20260829100000_feedback_sentiment_analysis.sql).

create table if not exists public.user_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null check (platform in ('web','android')),
  device_label text,
  enabled boolean not null default true,
  failure_count integer not null default 0 check (failure_count >= 0),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists user_push_tokens_user_idx
  on public.user_push_tokens(user_id) where enabled;

alter table public.user_push_tokens enable row level security;
revoke all on public.user_push_tokens from public, anon, authenticated;
grant select, insert, update, delete on public.user_push_tokens to authenticated;
grant select, update on public.user_push_tokens to service_role;

drop policy if exists user_push_tokens_own on public.user_push_tokens;
create policy user_push_tokens_own on public.user_push_tokens
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create table if not exists public.push_deliveries (
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
  sent_count integer not null default 0,
  created_at timestamptz not null default now(),
  constraint push_deliveries_one_per_notification unique (notification_id)
);
create index if not exists push_deliveries_pending_due_idx
  on public.push_deliveries(next_attempt_at, created_at)
  where status = 'pending';
create index if not exists push_deliveries_processing_stale_idx
  on public.push_deliveries(locked_at)
  where status = 'processing';

alter table public.push_deliveries enable row level security;
revoke all on public.push_deliveries from public, anon, authenticated;
grant select, insert, update on public.push_deliveries to service_role;

-- Maps a notification kind to the matching notification_preferences column.
-- Kinds already gated at insert time (e.g. reservation decisions inside
-- notify_reservation_user) are intentionally not re-checked here, and
-- admin-facing kinds (anomalies, feedback, loyalty) are never suppressed by
-- a renter-facing toggle.
create or replace function public.push_kind_allowed(p_recipient uuid, p_kind text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_kind = 'reservation_reminder' then
      coalesce(
        (select day_before_reminders from public.notification_preferences
         where user_id = p_recipient),
        true
      )
    when p_kind like 'new_facilit%' then
      coalesce(
        (select new_facilities from public.notification_preferences
         where user_id = p_recipient),
        false
      )
    else true
  end;
$$;

revoke all on function public.push_kind_allowed(uuid, text) from public, anon, authenticated;
grant execute on function public.push_kind_allowed(uuid, text) to service_role, authenticated;

-- Best-effort nudge: wakes the dispatch worker immediately instead of
-- waiting for the next cron tick. A missing pg_net/vault secret must never
-- fail the caller, so every failure mode here is swallowed.
create or replace function public.invoke_push_dispatch_worker()
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
      using 'smartreserve_push_worker_key'
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
        trim(trailing '/' from function_base_url) || '/functions/v1/send-push',
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

revoke all on function public.invoke_push_dispatch_worker() from public, anon, authenticated;
grant execute on function public.invoke_push_dispatch_worker() to service_role;

create or replace function public.enqueue_push_delivery()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  has_token boolean;
  allowed boolean;
begin
  begin
    allowed := public.push_kind_allowed(new.recipient_id, new.kind);
    has_token := exists (
      select 1 from public.user_push_tokens
      where user_id = new.recipient_id and enabled
    );

    insert into public.push_deliveries(
      notification_id, recipient_id, status, next_attempt_at
    )
    values (
      new.id,
      new.recipient_id,
      case when allowed and has_token then 'pending' else 'skipped' end,
      case when allowed and has_token then now() else null end
    )
    on conflict (notification_id) do nothing;

    if allowed and has_token then
      perform public.invoke_push_dispatch_worker();
    end if;
  exception
    when others then
      return new;
  end;

  return new;
end;
$$;

revoke all on function public.enqueue_push_delivery() from public, anon, authenticated;

drop trigger if exists app_notifications_enqueue_push on public.app_notifications;
create trigger app_notifications_enqueue_push
after insert on public.app_notifications
for each row execute procedure public.enqueue_push_delivery();

-- Leases due deliveries for the send-push worker, reclaiming stale leases
-- first. Returns each delivery joined to its notification content and the
-- recipient's currently enabled tokens.
create or replace function public.lease_push_deliveries(
  p_limit integer default 25,
  p_lease_seconds integer default 120,
  p_max_attempts integer default 5
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bounded_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
  result_value jsonb;
begin
  if coalesce(p_max_attempts, 5) < 1 then
    raise exception using errcode = '22023', message = 'Invalid max attempts';
  end if;

  update public.push_deliveries
  set status = 'failed',
      last_error_code = 'stale_processing',
      next_attempt_at = null,
      locked_at = null
  where status = 'processing'
    and coalesce(locked_at, created_at)
      < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120)))
    and attempt_count >= coalesce(p_max_attempts, 5);

  with candidates as (
    select d.id
    from public.push_deliveries d
    where d.attempt_count < coalesce(p_max_attempts, 5)
      and (
        (d.status = 'pending' and coalesce(d.next_attempt_at, d.created_at) <= now())
        or
        (d.status = 'processing'
          and coalesce(d.locked_at, d.created_at)
            < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120))))
      )
    order by coalesce(d.next_attempt_at, d.created_at), d.created_at
    for update of d skip locked
    limit bounded_limit
  ),
  claimed as (
    update public.push_deliveries d
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
      'tokens', (
        select coalesce(jsonb_agg(t.token), '[]'::jsonb)
        from public.user_push_tokens t
        where t.user_id = c.recipient_id and t.enabled
      )
    ) order by c.created_at), '[]'::jsonb)
  )
  into result_value
  from claimed c
  join public.app_notifications n on n.id = c.notification_id;

  return coalesce(result_value, jsonb_build_object('rows', '[]'::jsonb));
end;
$$;

revoke all on function public.lease_push_deliveries(integer, integer, integer)
from public, anon, authenticated;
grant execute on function public.lease_push_deliveries(integer, integer, integer)
to service_role;

-- Finalizes a leased delivery. On retryable failure, applies exponential
-- backoff; dead tokens (p_dead_tokens) are disabled so they stop being
-- returned by lease_push_deliveries regardless of the delivery outcome.
create or replace function public.complete_push_delivery(
  p_id uuid,
  p_status text,
  p_sent_count integer default 0,
  p_error_code text default null,
  p_dead_tokens text[] default null,
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

  if p_dead_tokens is not null and array_length(p_dead_tokens, 1) > 0 then
    update public.user_push_tokens
    set enabled = false, failure_count = failure_count + 1
    where token = any(p_dead_tokens);
  end if;

  select attempt_count into attempt_value
  from public.push_deliveries
  where id = p_id and status = 'processing'
  for update;

  if not found then
    return;
  end if;

  if p_status = 'sent' then
    update public.push_deliveries
    set status = 'sent',
        sent_count = coalesce(p_sent_count, 0),
        last_error_code = null,
        next_attempt_at = null,
        locked_at = null
    where id = p_id;
    return;
  end if;

  if attempt_value >= coalesce(p_max_attempts, 5) then
    update public.push_deliveries
    set status = 'failed',
        last_error_code = left(coalesce(p_error_code, 'send_failed'), 80),
        next_attempt_at = null,
        locked_at = null
    where id = p_id;
    return;
  end if;

  retry_seconds := least((60 * power(2, greatest(attempt_value - 1, 0)))::integer, 1800);
  update public.push_deliveries
  set status = 'pending',
      last_error_code = left(coalesce(p_error_code, 'send_failed'), 80),
      next_attempt_at = now() + make_interval(secs => retry_seconds),
      locked_at = null
  where id = p_id;
end;
$$;

revoke all on function public.complete_push_delivery(uuid, text, integer, text, text[], integer)
from public, anon, authenticated;
grant execute on function public.complete_push_delivery(uuid, text, integer, text, text[], integer)
to service_role;

do $$
begin
  begin
    create extension if not exists pg_net;
  exception
    when feature_not_supported or insufficient_privilege or undefined_file then
      raise notice 'pg_net is not available; configure it before enabling push delivery.';
  end;

  begin
    create extension if not exists pg_cron;
  exception
    when feature_not_supported or insufficient_privilege or undefined_file then
      raise notice 'pg_cron is not available; configure it before enabling push delivery.';
  end;

  begin
    if exists (select 1 from pg_namespace where nspname = 'cron') then
      if not exists (
        select 1 from cron.job where jobname = 'smartreserve-push-dispatch'
      ) then
        perform cron.schedule(
          'smartreserve-push-dispatch',
          '* * * * *',
          'select public.invoke_push_dispatch_worker();'
        );
      end if;
    end if;
  exception
    when invalid_schema_name or undefined_table or undefined_function
      or insufficient_privilege then
      raise notice 'push dispatch cron scheduling was skipped; configure pg_cron manually before enabling the worker.';
  end;
end $$;

notify pgrst, 'reload schema';
