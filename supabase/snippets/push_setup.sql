-- Push notification setup + health check.
--
-- Run section 1 once in the Supabase SQL editor (Dashboard → SQL Editor),
-- after replacing the two placeholders. Sections 2 and 3 are read-only and
-- safe to re-run whenever you want to know whether push is working.
--
-- Edge function secrets are set separately (Dashboard → Edge Functions →
-- Secrets, or the CLI):
--   supabase secrets set FCM_PROJECT_ID=smartreserve-48784
--   supabase secrets set FCM_SERVICE_ACCOUNT_JSON="$(cat service-account.json)"
--   supabase secrets set PUSH_WORKER_KEY=<same value as smartreserve_push_worker_key below>
--   supabase functions deploy send-push

-- ---------------------------------------------------------------------------
-- 1. One-time setup
-- ---------------------------------------------------------------------------
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- The project URL, e.g. https://tyniwgrvfxkfzhbiufib.supabase.co (no trailing
-- slash). Skip if the feedback-sentiment worker already created it.
select vault.create_secret(
  'https://YOUR-PROJECT-REF.supabase.co',
  'smartreserve_function_url'
)
where not exists (
  select 1 from vault.secrets where name = 'smartreserve_function_url'
);

-- Any long random string; must equal the PUSH_WORKER_KEY function secret.
-- Generate one with: openssl rand -hex 32
select vault.create_secret(
  'REPLACE-WITH-THE-PUSH_WORKER_KEY-VALUE',
  'smartreserve_push_worker_key'
)
where not exists (
  select 1 from vault.secrets where name = 'smartreserve_push_worker_key'
);

-- Re-create the cron jobs in case the migrations ran before pg_cron existed.
select cron.schedule(
  'smartreserve-push-dispatch', '* * * * *',
  'select public.invoke_push_dispatch_worker();'
)
where not exists (
  select 1 from cron.job where jobname = 'smartreserve-push-dispatch'
);
select cron.schedule(
  'smartreserve-day-before-reminders', '*/5 * * * *',
  'select public.send_day_before_reminders();'
)
where not exists (
  select 1 from cron.job where jobname = 'smartreserve-day-before-reminders'
);

-- ---------------------------------------------------------------------------
-- 2. Configuration check (every row should say ok)
-- ---------------------------------------------------------------------------
select 'pg_net installed' as check_name,
       case when exists (select 1 from pg_extension where extname = 'pg_net')
            then 'ok' else 'MISSING' end as result
union all
select 'pg_cron installed',
       case when exists (select 1 from pg_extension where extname = 'pg_cron')
            then 'ok' else 'MISSING' end
union all
select 'vault: smartreserve_function_url',
       case when exists (select 1 from vault.secrets where name = 'smartreserve_function_url')
            then 'ok' else 'MISSING' end
union all
select 'vault: smartreserve_push_worker_key',
       case when exists (select 1 from vault.secrets where name = 'smartreserve_push_worker_key')
            then 'ok' else 'MISSING' end
union all
select 'cron: push dispatch',
       case when exists (select 1 from cron.job where jobname = 'smartreserve-push-dispatch' and active)
            then 'ok' else 'MISSING' end
union all
select 'cron: day-before reminders',
       case when exists (select 1 from cron.job where jobname = 'smartreserve-day-before-reminders' and active)
            then 'ok' else 'MISSING' end
union all
select 'devices registered (enabled tokens)',
       (select count(*)::text from public.user_push_tokens where enabled);

-- ---------------------------------------------------------------------------
-- 3. Delivery health
-- ---------------------------------------------------------------------------
-- sent     → working.
-- pending  → piling up means the worker never runs (vault/cron/pg_net, or the
--            function is unreachable). Check section 2 and the function logs.
-- skipped  → recipient had no enabled device or turned that kind off.
-- failed   → last_error_code is FCM's reason (e.g. PERMISSION_DENIED or an
--            auth error = wrong service account JSON / FCM API not enabled).
select status, last_error_code, count(*) as deliveries, max(created_at) as latest
from public.push_deliveries
where created_at > now() - interval '7 days'
group by status, last_error_code
order by latest desc;

-- What the send-push endpoint answered to the most recent nudges:
-- 200 = ran (body shows claimed/sent), 401 unauthorized = PUSH_WORKER_KEY
-- differs from the vault key, 500 configuration_error = FCM secrets missing,
-- 404 = send-push not deployed.
select created, status_code, left(content::text, 200) as response
from net._http_response
order by created desc
limit 10;
