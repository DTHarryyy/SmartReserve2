-- Price the turn against the model that actually served it.
--
-- The previous rates were described as conservative placeholders. They were
-- not placeholders: 150 and 600 micro-USD per 1k tokens are exactly
-- gpt-4o-mini's published prices ($0.15 and $0.60 per million). What they were
-- was unconditional -- p_model was recorded and then ignored, so changing
-- ASSISTANT_MODEL would have kept reporting gpt-4o-mini's bill for a different
-- model's spend, and the number is only useful if it is the real one.
--
-- Rates live here rather than in the function so a price change is one
-- migration and no redeploy. An unrecognised model falls back to the most
-- expensive listed rate: over-reporting spend prompts a look, under-reporting
-- hides it.
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
  model_key text := lower(coalesce(p_model, ''));
  input_micro_usd_per_1k numeric;
  output_micro_usd_per_1k numeric;
  estimated_cost integer;
begin
  -- micro-USD per 1,000 tokens.
  if model_key like 'gpt-4o-mini%' then
    input_micro_usd_per_1k := 150;    -- $0.15 / 1M
    output_micro_usd_per_1k := 600;   -- $0.60 / 1M
  elsif model_key like 'gpt-4.1-mini%' then
    input_micro_usd_per_1k := 400;
    output_micro_usd_per_1k := 1600;
  elsif model_key like 'gpt-4o%' then
    input_micro_usd_per_1k := 2500;
    output_micro_usd_per_1k := 10000;
  else
    input_micro_usd_per_1k := 2500;
    output_micro_usd_per_1k := 10000;
  end if;

  estimated_cost := greatest(0, round((
    coalesce(p_input_tokens, 0) * input_micro_usd_per_1k
    + coalesce(p_output_tokens, 0) * output_micro_usd_per_1k
  ) / 1000.0)::integer);

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
    greatest(coalesce(p_input_tokens, 0), 0),
    greatest(coalesce(p_output_tokens, 0), 0),
    estimated_cost,
    greatest(coalesce(p_latency_ms, 0), 0),
    greatest(coalesce(p_tool_rounds, 0), 0),
    coalesce(nullif(p_outcome, ''), 'answered'),
    p_error_code
  );
end;
$$;

revoke execute on function public.assistant_log_llm_request(
  uuid, uuid, uuid, text, text[], text, text, integer, integer, integer,
  integer, text, text, text
) from public, anon, authenticated;
grant execute on function public.assistant_log_llm_request(
  uuid, uuid, uuid, text, text[], text, text, integer, integer, integer,
  integer, text, text, text
) to service_role;

-- Expired cache rows had no sweeper; assistant_cache_get filters them, so they
-- were invisible but permanent.
create or replace function public.assistant_purge_expired_cache()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  removed integer;
begin
  delete from public.assistant_response_cache where expires_at <= now();
  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke execute on function public.assistant_purge_expired_cache() from public, anon, authenticated;
grant execute on function public.assistant_purge_expired_cache() to service_role;

notify pgrst, 'reload schema';
