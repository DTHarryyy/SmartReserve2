-- The rate limiter is what stands between a runaway client and a provider
-- bill, so the properties that matter are: it actually refuses past the cap,
-- it counts each request exactly once, and the window genuinely resets.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(11);

create temp table assistant_rate_actor as
select id as user_id from public.profiles order by created_at limit 1;

select ok((select user_id is not null from assistant_rate_actor),
  'the fixture found an account to meter');

select has_function('public', 'assistant_consume_rate_limit',
  array['uuid', 'integer', 'integer'],
  'assistant_consume_rate_limit exists');
select has_function('public', 'assistant_log_llm_request',
  array['uuid', 'uuid', 'uuid', 'text', 'text[]', 'text', 'text',
        'integer', 'integer', 'integer', 'integer', 'text', 'text', 'text'],
  'assistant_log_llm_request exists');

-- These are worker functions. A signed-in client calling them directly could
-- clear its own counter, so only the service role may.
select ok(
  not has_function_privilege('authenticated',
    'public.assistant_consume_rate_limit(uuid, integer, integer)', 'execute'),
  'a signed-in client cannot reset its own rate limit'
);
select ok(
  not has_function_privilege('anon',
    'public.assistant_consume_rate_limit(uuid, integer, integer)', 'execute'),
  'anon cannot touch the rate limiter'
);
select ok(
  has_function_privilege('service_role',
    'public.assistant_consume_rate_limit(uuid, integer, integer)', 'execute'),
  'the edge function can meter requests'
);

delete from public.assistant_rate_limits
where user_id = (select user_id from assistant_rate_actor);

-- Three allowed, then refused. Counted here rather than asserted one call at a
-- time so an off-by-one in either direction shows up.
create temp table assistant_rate_probe as
select
  i,
  public.assistant_consume_rate_limit(
    (select user_id from assistant_rate_actor), 3600, 3
  ) as verdict
from generate_series(1, 6) as i;

select is(
  (select count(*) from assistant_rate_probe
   where (verdict ->> 'allowed')::boolean),
  3::bigint,
  'exactly the first three requests are allowed'
);
select is(
  (select count(*) from assistant_rate_probe
   where not (verdict ->> 'allowed')::boolean),
  3::bigint,
  'everything past the cap is refused'
);
select ok(
  (select (verdict ->> 'retry_after_seconds')::int > 0
   from assistant_rate_probe
   where not (verdict ->> 'allowed')::boolean
   order by i limit 1),
  'a refusal carries a usable wait hint'
);

-- A window that has aged out starts a fresh count rather than staying blocked.
update public.assistant_rate_limits
set window_started_at = now() - interval '2 hours'
where user_id = (select user_id from assistant_rate_actor);

select is(
  (public.assistant_consume_rate_limit(
    (select user_id from assistant_rate_actor), 3600, 3
  ) ->> 'allowed')::boolean,
  true,
  'the window resets once it has elapsed'
);

-- Telemetry records the cost, and records no message text to record.
select public.assistant_log_llm_request(
  gen_random_uuid(),
  (select user_id from assistant_rate_actor),
  null, 'llm', array['get_payment_balance'], 'openai', 'gpt-4o-mini',
  900, 90, 1200, 1, 'answered', null, 'paymentBalance'
);

select ok(
  (select cost_micro_usd > 0 from public.assistant_llm_requests
   order by created_at desc limit 1),
  'a logged request carries an estimated cost'
);

select * from finish();
rollback;
