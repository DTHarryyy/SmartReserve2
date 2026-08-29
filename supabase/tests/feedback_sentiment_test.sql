begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(23);

create temp table feedback_sentiment_test as
select
  (select id from public.profiles where lower(email) = 'user@csu.edu.ph') user_id,
  (select id from public.profiles where lower(email) = 'admin@csu.edu.ph') internal_admin_id,
  (select id from public.profiles where lower(email) = 'external-admin@csu.edu.ph') external_admin_id,
  '10000000-0000-0000-0000-000000000001'::uuid facility_id;

insert into public.reservation_requests(
  id, requester_id, facility_id, requester_name, requester_role,
  facility_name, facility_building, facility_capacity, purpose, headcount,
  status, reservation_status, admin_lane, pricing_audience, created_at
)
select '98200000-0000-0000-0000-000000000001', user_id, facility_id,
  'Sentiment Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Positive sentiment test', 10, 'approved', 'completed', 'internal', 'guest', now()
from feedback_sentiment_test
union all
select '98200000-0000-0000-0000-000000000002', user_id, facility_id,
  'Sentiment Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Blank comment test', 10, 'approved', 'completed', 'internal', 'guest', now()
from feedback_sentiment_test
union all
select '98200000-0000-0000-0000-000000000003', user_id, facility_id,
  'Sentiment Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Negative retry test', 10, 'approved', 'completed', 'internal', 'guest', now()
from feedback_sentiment_test
union all
select '98200000-0000-0000-0000-000000000004', user_id, facility_id,
  'Sentiment Test', 'user', 'Computer Laboratory 1', 'CICS', 40,
  'Mixed sentiment test', 10, 'approved', 'completed', 'internal', 'guest', now()
from feedback_sentiment_test;

insert into public.reservation_occurrences(
  id, request_id, facility_id, starts_at, ends_at, booking_state, lifecycle_stage
)
select '98300000-0000-0000-0000-000000000001',
  '98200000-0000-0000-0000-000000000001', facility_id,
  now() - interval '4 days', now() - interval '4 days' + interval '1 hour',
  'booked', 'completed'
from feedback_sentiment_test
union all
select '98300000-0000-0000-0000-000000000002',
  '98200000-0000-0000-0000-000000000002', facility_id,
  now() - interval '3 days', now() - interval '3 days' + interval '1 hour',
  'booked', 'completed'
from feedback_sentiment_test
union all
select '98300000-0000-0000-0000-000000000003',
  '98200000-0000-0000-0000-000000000003', facility_id,
  now() - interval '2 days', now() - interval '2 days' + interval '1 hour',
  'booked', 'completed'
from feedback_sentiment_test
union all
select '98300000-0000-0000-0000-000000000004',
  '98200000-0000-0000-0000-000000000004', facility_id,
  now() - interval '1 day', now() - interval '1 day' + interval '1 hour',
  'booked', 'completed'
from feedback_sentiment_test;

select set_config(
  'request.jwt.claim.sub',
  (select user_id::text from feedback_sentiment_test),
  false
);

select public.submit_reservation_feedback(
  '98200000-0000-0000-0000-000000000001',
  5,
  'The gym was clean and the staff were very accommodating.'
);
select public.submit_reservation_feedback(
  '98200000-0000-0000-0000-000000000002',
  4,
  ''
);
select public.submit_reservation_feedback(
  '98200000-0000-0000-0000-000000000003',
  2,
  'The facility was dirty and nobody assisted us.'
);
select public.submit_reservation_feedback(
  '98200000-0000-0000-0000-000000000004',
  3,
  'Okay lang ang room, pero ang tagal ng approval.'
);

select is(
  (select count(*)::int from public.feedback_sentiment_analyses
   where status = 'pending'),
  3,
  'written feedback is queued for sentiment analysis'
);

select is(
  (select count(*)::int from public.feedback_sentiment_analyses
   where status = 'skipped'),
  1,
  'blank feedback is skipped without a provider call'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  (select user_id::text from feedback_sentiment_test),
  false
);

select is(
  (select count(*)::int from public.feedback_sentiment_analyses),
  0,
  'ordinary users cannot read sentiment-analysis rows'
);

select throws_ok(
  $$select public.feedback_sentiment_claim()$$,
  '42501',
  'permission denied for function feedback_sentiment_claim',
  'authenticated clients cannot execute the service-only claim RPC'
);

select throws_ok(
  $$select public.feedback_sentiment_retry(
    (select id from public.reservation_feedback
     where reservation_id = '98200000-0000-0000-0000-000000000001')
  )$$,
  '42501',
  'Administrator access required',
  'ordinary users cannot retry sentiment analysis'
);

select set_config(
  'request.jwt.claim.sub',
  (select internal_admin_id::text from feedback_sentiment_test),
  false
);

select is(
  (select count(*)::int from public.feedback_sentiment_analyses),
  4,
  'internal administrators can read sentiment-analysis rows'
);

reset role;

create temp table claimed_feedback_sentiment as
select public.feedback_sentiment_claim(1, 1, 120, 3) result;

select is(
  (select jsonb_array_length(result -> 'rows') from claimed_feedback_sentiment),
  1,
  'the service claim RPC claims a bounded batch'
);

create temp table claimed_analysis as
select ((result -> 'rows' -> 0) ->> 'id')::uuid id
from claimed_feedback_sentiment;

select is(
  (select status from public.feedback_sentiment_analyses
   where id = (select id from claimed_analysis)),
  'processing',
  'claimed rows enter processing status'
);

select is(
  (select attempt_count from public.feedback_sentiment_analyses
   where id = (select id from claimed_analysis)),
  1,
  'claiming increments the attempt counter'
);

select lives_ok(
  $$select public.feedback_sentiment_complete(
    (select id from claimed_analysis),
    1,
    'positive',
    0.94,
    '[{"topic":"facility_cleanliness","sentiment":"positive"},{"topic":"staff_service","sentiment":"positive"}]'::jsonb,
    'groq',
    'openai/gpt-oss-20b'
  )$$,
  'a valid sentiment result can be completed'
);

select is(
  (select sentiment from public.feedback_sentiment_analyses
   where id = (select id from claimed_analysis)),
  'positive',
  'completed analysis stores the overall sentiment'
);

select ok(
  public.feedback_sentiment_topics_are_valid(
    '[{"topic":"approval_speed","sentiment":"negative"}]'::jsonb
  ),
  'a valid controlled topic payload passes validation'
);

select isnt(
  public.feedback_sentiment_topics_are_valid(
    '[{"topic":"staff_service","sentiment":"positive"},{"topic":"staff_service","sentiment":"negative"}]'::jsonb
  ),
  true,
  'duplicate topics are rejected'
);

select isnt(
  public.feedback_sentiment_topics_are_valid(
    '[{"topic":"facility_cleanliness","sentiment":"negative"},{"topic":"facility_condition","sentiment":"negative"},{"topic":"staff_service","sentiment":"positive"},{"topic":"payment_process","sentiment":"negative"}]'::jsonb
  ),
  true,
  'more than three topics are rejected'
);

create temp table failed_claim as
select public.feedback_sentiment_claim(1, 1, 120, 3) result;

create temp table failed_analysis as
select ((result -> 'rows' -> 0) ->> 'id')::uuid id
from failed_claim;

select public.feedback_sentiment_fail(
  (select id from failed_analysis),
  1,
  'provider_timeout',
  null,
  3,
  'groq',
  'openai/gpt-oss-20b'
);

select is(
  (select status from public.feedback_sentiment_analyses
   where id = (select id from failed_analysis)),
  'pending',
  'a transient first failure is rescheduled'
);

update public.feedback_sentiment_analyses
set status = 'processing', attempt_count = 3
where id = (select id from failed_analysis);

select public.feedback_sentiment_fail(
  (select id from failed_analysis),
  1,
  'provider_unavailable',
  null,
  3,
  'groq',
  'openai/gpt-oss-20b'
);

select is(
  (select status from public.feedback_sentiment_analyses
   where id = (select id from failed_analysis)),
  'failed',
  'the final automatic failure is terminal'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  (select internal_admin_id::text from feedback_sentiment_test),
  false
);

select public.feedback_sentiment_retry(
  (select feedback_id from public.feedback_sentiment_analyses
   where id = (select id from failed_analysis))
);

select is(
  (select status from public.feedback_sentiment_analyses
   where id = (select id from failed_analysis)),
  'pending',
  'an administrator can reset a failed analysis for retry'
);

select is(
  (select count(*)::int from public.feedback_sentiment_analyses
   where feedback_id = (
     select feedback_id from public.feedback_sentiment_analyses
     where id = (select id from failed_analysis)
   )),
  1,
  'retry does not create a duplicate version row'
);

reset role;

delete from public.feedback_sentiment_analyses
where feedback_id = (
  select id from public.reservation_feedback
  where reservation_id = '98200000-0000-0000-0000-000000000002'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  (select internal_admin_id::text from feedback_sentiment_test),
  false
);

select public.feedback_sentiment_backfill(10);

select is(
  (select status from public.feedback_sentiment_analyses
   where feedback_id = (
     select id from public.reservation_feedback
     where reservation_id = '98200000-0000-0000-0000-000000000002'
   )),
  'skipped',
  'backfill recreates missing blank-comment rows as skipped'
);

select set_config(
  'request.jwt.claim.sub',
  (select external_admin_id::text from feedback_sentiment_test),
  false
);

select throws_ok(
  $$select public.feedback_sentiment_backfill(10)$$,
  '42501',
  'Internal administrator access required',
  'external administrators cannot queue bulk backfills'
);

select is(
  ((public.feedback_sentiment_analytics() ->> 'total_feedback')::int),
  4,
  'sentiment analytics counts visible feedback'
);

select is(
  ((public.feedback_sentiment_analytics() ->> 'needs_review')::int),
  1,
  'sentiment analytics deduplicates needs-review feedback'
);

select is(
  ((public.feedback_sentiment_analytics() ->> 'positive')::int),
  1,
  'sentiment analytics counts completed positive sentiment'
);

select * from finish();
rollback;
