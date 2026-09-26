-- Cost control and accountability for model-assisted turns.
--
-- Three things live here, and none of them stores what anyone said -- the
-- transcript already lives in assistant_messages, and duplicating it into a
-- telemetry table would widen the data footprint for no benefit:
--
--   assistant_llm_requests  what a request cost and how it ended. The
--                           'fallback' and 'unknown intent' rows are the
--                           backlog for new deterministic rules, which is how
--                           model spend goes down over time rather than up.
--   assistant_rate_limits   a per-user token bucket, consumed before the
--                           provider is called so an exhausted user costs
--                           nothing.
--   assistant_response_cache stable policy answers, keyed by the normalized
--                           question, so the same FAQ is not paid for twice.

create table if not exists public.assistant_llm_requests (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  user_id uuid references public.profiles(id) on delete set null,
  conversation_id uuid references public.assistant_conversations(id) on delete set null,
  route text not null default 'llm' check (route in ('rule', 'cache', 'llm')),
  resolved_intent text,
  tools_used text[] not null default '{}',
  provider text,
  model text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  cost_micro_usd integer not null default 0 check (cost_micro_usd >= 0),
  latency_ms integer not null default 0 check (latency_ms >= 0),
  tool_rounds integer not null default 0 check (tool_rounds >= 0),
  outcome text not null check (outcome in (
    'answered', 'fallback', 'rate_limited', 'error'
  )),
  error_code text,
  created_at timestamptz not null default now()
);

create index if not exists assistant_llm_requests_created_idx
  on public.assistant_llm_requests (created_at desc);
create index if not exists assistant_llm_requests_outcome_idx
  on public.assistant_llm_requests (outcome, created_at desc);

create table if not exists public.assistant_rate_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0 check (request_count >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.assistant_response_cache (
  cache_key text primary key,
  answer text not null check (char_length(answer) between 1 and 2000),
  audience text not null,
  hit_count integer not null default 0 check (hit_count >= 0),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists assistant_response_cache_expiry_idx
  on public.assistant_response_cache (expires_at);

alter table public.assistant_llm_requests enable row level security;
alter table public.assistant_rate_limits enable row level security;
alter table public.assistant_response_cache enable row level security;

-- Written only by the edge function under the service role. No client, admin
-- or otherwise, writes these directly.
revoke all on public.assistant_llm_requests from public, anon, authenticated;
revoke all on public.assistant_rate_limits from public, anon, authenticated;
revoke all on public.assistant_response_cache from public, anon, authenticated;
grant select on public.assistant_llm_requests to authenticated;

-- Internal admins can read spend; nobody reads anybody else's usage, and the
-- table holds no message text to read in the first place.
drop policy if exists assistant_llm_requests_admin_read on public.assistant_llm_requests;
create policy assistant_llm_requests_admin_read
on public.assistant_llm_requests for select to authenticated
using (public.is_internal_admin());

-- ---------------------------------------------------------------------------
-- Rate limiting: a fixed window per user, consumed atomically.
--
-- The upsert plus the conditional window reset happen in one statement, so two
-- concurrent requests cannot both see a stale count and both be allowed.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_consume_rate_limit(
  p_user_id uuid,
  p_window_seconds integer default 3600,
  p_max integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  window_seconds integer := least(greatest(coalesce(p_window_seconds, 3600), 60), 86400);
  max_requests integer := least(greatest(coalesce(p_max, 30), 1), 1000);
  current_count integer;
  window_start timestamptz;
begin
  if p_user_id is null then
    raise exception using errcode = '22023', message = 'A user is required';
  end if;

  insert into public.assistant_rate_limits (user_id, window_started_at, request_count, updated_at)
  values (p_user_id, now(), 1, now())
  on conflict (user_id) do update set
    -- Reset the window and the count together, or increment within it.
    window_started_at = case
      when public.assistant_rate_limits.window_started_at
             < now() - make_interval(secs => window_seconds)
        then now()
      else public.assistant_rate_limits.window_started_at
    end,
    request_count = case
      when public.assistant_rate_limits.window_started_at
             < now() - make_interval(secs => window_seconds)
        then 1
      else public.assistant_rate_limits.request_count + 1
    end,
    updated_at = now()
  returning request_count, window_started_at into current_count, window_start;

  return jsonb_build_object(
    'allowed', current_count <= max_requests,
    'remaining', greatest(0, max_requests - current_count),
    'retry_after_seconds', case
      when current_count <= max_requests then 0
      else greatest(
        1,
        ceil(extract(epoch from (
          window_start + make_interval(secs => window_seconds) - now()
        )))::integer
      )
    end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Telemetry write. Cost is derived here rather than passed in, so a change of
-- provider price is one migration, not a redeploy of the function.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_log_llm_request(
  p_request_id uuid,
  p_user_id uuid,
  p_conversation_id uuid,
  p_route text,
  p_tools_used text[],
  p_provider text,
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_latency_ms integer,
  p_tool_rounds integer,
  p_outcome text,
  p_error_code text default null,
  p_resolved_intent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  input_micro_usd_per_1k integer := 150;   -- conservative placeholder rates
  output_micro_usd_per_1k integer := 600;
  estimated_cost integer;
begin
  estimated_cost := greatest(0, (
    coalesce(p_input_tokens, 0) * input_micro_usd_per_1k
    + coalesce(p_output_tokens, 0) * output_micro_usd_per_1k
  ) / 1000);

  insert into public.assistant_llm_requests (
    request_id, user_id, conversation_id, route, resolved_intent, tools_used,
    provider, model, input_tokens, output_tokens, cost_micro_usd, latency_ms,
    tool_rounds, outcome, error_code
  ) values (
    p_request_id,
    p_user_id,
    p_conversation_id,
    coalesce(nullif(p_route, ''), 'llm'),
    p_resolved_intent,
    coalesce(p_tools_used, '{}'),
    p_provider,
    p_model,
    greatest(0, coalesce(p_input_tokens, 0)),
    greatest(0, coalesce(p_output_tokens, 0)),
    estimated_cost,
    greatest(0, coalesce(p_latency_ms, 0)),
    greatest(0, coalesce(p_tool_rounds, 0)),
    p_outcome,
    p_error_code
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Cache. Keyed on the normalized question plus audience plus knowledge-base
-- version, so a policy edit invalidates every answer that quoted it.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_cache_get(p_cache_key text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  hit public.assistant_response_cache%rowtype;
begin
  select * into hit
  from public.assistant_response_cache
  where cache_key = p_cache_key and expires_at > now();

  if hit.cache_key is null then
    return jsonb_build_object('hit', false);
  end if;

  update public.assistant_response_cache
  set hit_count = hit_count + 1
  where cache_key = p_cache_key;

  return jsonb_build_object('hit', true, 'answer', hit.answer);
end;
$$;

create or replace function public.assistant_cache_put(
  p_cache_key text,
  p_answer text,
  p_audience text,
  p_ttl_seconds integer default 604800
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.assistant_response_cache (cache_key, answer, audience, expires_at)
  values (
    p_cache_key,
    left(p_answer, 2000),
    coalesce(nullif(p_audience, ''), 'guest'),
    now() + make_interval(secs => least(greatest(coalesce(p_ttl_seconds, 604800), 60), 2592000))
  )
  on conflict (cache_key) do update set
    answer = excluded.answer,
    expires_at = excluded.expires_at;
end;
$$;

-- These are worker functions: the edge function calls them with the service
-- role. No signed-in client has any business invoking them directly.
revoke execute on function public.assistant_consume_rate_limit(uuid, integer, integer)
  from public, anon, authenticated;
revoke execute on function public.assistant_log_llm_request(
  uuid, uuid, uuid, text, text[], text, text, integer, integer, integer, integer, text, text, text
) from public, anon, authenticated;
revoke execute on function public.assistant_cache_get(text) from public, anon, authenticated;
revoke execute on function public.assistant_cache_put(text, text, text, integer)
  from public, anon, authenticated;

grant execute on function public.assistant_consume_rate_limit(uuid, integer, integer)
  to service_role;
grant execute on function public.assistant_log_llm_request(
  uuid, uuid, uuid, text, text[], text, text, integer, integer, integer, integer, text, text, text
) to service_role;
grant execute on function public.assistant_cache_get(text) to service_role;
grant execute on function public.assistant_cache_put(text, text, text, integer) to service_role;

notify pgrst, 'reload schema';
