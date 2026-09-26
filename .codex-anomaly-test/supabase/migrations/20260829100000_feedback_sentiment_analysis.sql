-- Feedback sentiment analysis.
--
-- Sentiment is derived operational data. Keep it separate from
-- reservation_feedback so ordinary users can keep reading their own source
-- review rows without seeing administrator-only AI estimates.

create or replace function public.feedback_sentiment_topics_are_valid(p_topics jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  item jsonb;
  item_topic text;
  item_sentiment text;
  seen_topics text[] := array[]::text[];
begin
  if p_topics is null then
    return true;
  end if;
  if jsonb_typeof(p_topics) <> 'array' then
    return false;
  end if;
  if jsonb_array_length(p_topics) > 3 then
    return false;
  end if;

  for item in select value from jsonb_array_elements(p_topics)
  loop
    if jsonb_typeof(item) <> 'object' then
      return false;
    end if;
    if (select count(*) from jsonb_object_keys(item)) <> 2 then
      return false;
    end if;
    if not (item ? 'topic') or not (item ? 'sentiment') then
      return false;
    end if;

    item_topic := item ->> 'topic';
    item_sentiment := item ->> 'sentiment';

    if item_topic not in (
      'facility_cleanliness',
      'facility_condition',
      'reservation_process',
      'approval_speed',
      'staff_service',
      'payment_process',
      'equipment_availability',
      'overall_experience',
      'other'
    ) then
      return false;
    end if;

    if item_sentiment not in ('positive','neutral','negative','mixed') then
      return false;
    end if;

    if item_topic = any(seen_topics) then
      return false;
    end if;
    seen_topics := array_append(seen_topics, item_topic);
  end loop;

  return true;
end;
$$;

revoke all on function public.feedback_sentiment_topics_are_valid(jsonb)
  from public, anon, authenticated;
grant execute on function public.feedback_sentiment_topics_are_valid(jsonb)
  to service_role;

create table if not exists public.feedback_sentiment_analyses (
  id uuid primary key default gen_random_uuid(),
  feedback_id uuid not null
    references public.reservation_feedback(id) on delete cascade,
  analysis_version integer not null default 1
    check (analysis_version > 0),
  status text not null default 'pending'
    check (status in ('pending','processing','completed','failed','skipped')),
  sentiment text
    check (sentiment in ('positive','neutral','negative','mixed','unknown')),
  confidence numeric(4,3)
    check (confidence is null or confidence between 0 and 1),
  topic_sentiments jsonb not null default '[]'::jsonb
    check (public.feedback_sentiment_topics_are_valid(topic_sentiments)),
  provider text,
  model text,
  attempt_count integer not null default 0
    check (attempt_count between 0 and 20),
  next_attempt_at timestamptz,
  last_error_code text check (
    last_error_code is null
    or (last_error_code = lower(last_error_code)
      and last_error_code ~ '^[a-z0-9_]{2,80}$')
  ),
  processing_started_at timestamptz,
  analyzed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint feedback_sentiment_unique_version
    unique (feedback_id, analysis_version),
  constraint feedback_sentiment_completed_required check (
    status <> 'completed'
    or (
      sentiment is not null
      and confidence is not null
      and provider is not null
      and model is not null
      and analyzed_at is not null
    )
  ),
  constraint feedback_sentiment_failed_required check (
    status <> 'failed' or last_error_code is not null
  ),
  constraint feedback_sentiment_skipped_is_empty check (
    status <> 'skipped'
    or (
      sentiment is null
      and confidence is null
      and provider is null
      and model is null
      and analyzed_at is null
      and last_error_code is null
    )
  )
);

create index if not exists feedback_sentiment_pending_due_idx
  on public.feedback_sentiment_analyses(next_attempt_at, created_at)
  where status = 'pending';
create index if not exists feedback_sentiment_processing_stale_idx
  on public.feedback_sentiment_analyses(processing_started_at)
  where status = 'processing';
create index if not exists feedback_sentiment_completed_idx
  on public.feedback_sentiment_analyses(sentiment, analyzed_at desc)
  where status = 'completed';
create index if not exists feedback_sentiment_feedback_version_idx
  on public.feedback_sentiment_analyses(feedback_id, analysis_version desc);
create index if not exists feedback_sentiment_topics_idx
  on public.feedback_sentiment_analyses using gin(topic_sentiments);

drop trigger if exists feedback_sentiment_analyses_updated_at
on public.feedback_sentiment_analyses;
create trigger feedback_sentiment_analyses_updated_at
before update on public.feedback_sentiment_analyses
for each row execute procedure public.set_updated_at();

alter table public.feedback_sentiment_analyses enable row level security;

revoke all on public.feedback_sentiment_analyses from public, anon, authenticated;
grant select on public.feedback_sentiment_analyses to authenticated;
grant select, insert, update, delete on public.feedback_sentiment_analyses to service_role;

drop policy if exists feedback_sentiment_admin_read
on public.feedback_sentiment_analyses;
create policy feedback_sentiment_admin_read
on public.feedback_sentiment_analyses for select to authenticated
using (
  (select public.is_internal_admin())
  or (select public.is_external_admin())
);

create or replace function public.queue_feedback_sentiment_analysis()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    insert into public.feedback_sentiment_analyses(
      feedback_id,
      analysis_version,
      status,
      next_attempt_at
    )
    values (
      new.id,
      1,
      case when length(trim(coalesce(new.comment, ''))) = 0
        then 'skipped'
        else 'pending'
      end,
      case when length(trim(coalesce(new.comment, ''))) = 0
        then null
        else now()
      end
    )
    on conflict (feedback_id, analysis_version) do nothing;
  exception
    when others then
      return new;
  end;

  return new;
end;
$$;

revoke all on function public.queue_feedback_sentiment_analysis()
from public, anon, authenticated;

drop trigger if exists reservation_feedback_queue_sentiment
on public.reservation_feedback;
create trigger reservation_feedback_queue_sentiment
after insert on public.reservation_feedback
for each row execute procedure public.queue_feedback_sentiment_analysis();

create or replace function public.feedback_sentiment_claim(
  p_limit integer default 5,
  p_version integer default 1,
  p_lease_seconds integer default 120,
  p_max_attempts integer default 3
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bounded_limit integer := greatest(1, least(coalesce(p_limit, 5), 25));
  result_value jsonb;
begin
  if coalesce(p_version, 1) < 1 then
    raise exception using errcode = '22023', message = 'Invalid analysis version';
  end if;
  if coalesce(p_max_attempts, 3) < 1 then
    raise exception using errcode = '22023', message = 'Invalid max attempts';
  end if;

  update public.feedback_sentiment_analyses
  set status = 'failed',
      last_error_code = 'stale_processing',
      next_attempt_at = null,
      processing_started_at = null
  where status = 'processing'
    and coalesce(processing_started_at, created_at)
      < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120)))
    and attempt_count >= coalesce(p_max_attempts, 3);

  with candidates as (
    select a.id
    from public.feedback_sentiment_analyses a
    join public.reservation_feedback f on f.id = a.feedback_id
    where a.analysis_version = coalesce(p_version, 1)
      and length(trim(coalesce(f.comment, ''))) > 0
      and a.attempt_count < coalesce(p_max_attempts, 3)
      and (
        (a.status = 'pending'
          and coalesce(a.next_attempt_at, a.created_at) <= now())
        or
        (a.status = 'processing'
          and coalesce(a.processing_started_at, a.created_at)
            < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120))))
      )
    order by coalesce(a.next_attempt_at, a.created_at), a.created_at
    for update of a skip locked
    limit bounded_limit
  ),
  claimed as (
    update public.feedback_sentiment_analyses a
    set status = 'processing',
        processing_started_at = now(),
        next_attempt_at = null,
        last_error_code = null,
        attempt_count = a.attempt_count + 1
    from candidates c
    where a.id = c.id
    returning a.*
  )
  select jsonb_build_object(
    'rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id,
      'feedback_id', c.feedback_id,
      'analysis_version', c.analysis_version,
      'attempt_count', c.attempt_count,
      'comment', f.comment
    ) order by c.created_at), '[]'::jsonb)
  )
  into result_value
  from claimed c
  join public.reservation_feedback f on f.id = c.feedback_id;

  return coalesce(result_value, jsonb_build_object('rows', '[]'::jsonb));
end;
$$;

revoke all on function public.feedback_sentiment_claim(integer, integer, integer, integer)
from public, anon, authenticated;
grant execute on function public.feedback_sentiment_claim(integer, integer, integer, integer)
to service_role;

create or replace function public.feedback_sentiment_complete(
  p_analysis_id uuid,
  p_version integer,
  p_sentiment text,
  p_confidence numeric,
  p_topic_sentiments jsonb,
  p_provider text,
  p_model text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_analysis_id is null then
    raise exception using errcode = '22023', message = 'Analysis id is required';
  end if;
  if coalesce(p_version, 1) < 1 then
    raise exception using errcode = '22023', message = 'Invalid analysis version';
  end if;
  if p_sentiment not in ('positive','neutral','negative','mixed','unknown') then
    raise exception using errcode = '22023', message = 'Invalid sentiment';
  end if;
  if p_confidence is null or p_confidence < 0 or p_confidence > 1 then
    raise exception using errcode = '22023', message = 'Invalid confidence';
  end if;
  if not public.feedback_sentiment_topics_are_valid(coalesce(p_topic_sentiments, '[]'::jsonb)) then
    raise exception using errcode = '22023', message = 'Invalid sentiment topics';
  end if;
  if nullif(trim(coalesce(p_provider, '')), '') is null
     or nullif(trim(coalesce(p_model, '')), '') is null then
    raise exception using errcode = '22023', message = 'Provider and model are required';
  end if;

  update public.feedback_sentiment_analyses
  set status = 'completed',
      sentiment = p_sentiment,
      confidence = round(p_confidence, 3),
      topic_sentiments = coalesce(p_topic_sentiments, '[]'::jsonb),
      provider = left(trim(p_provider), 80),
      model = left(trim(p_model), 120),
      last_error_code = null,
      next_attempt_at = null,
      processing_started_at = null,
      analyzed_at = now()
  where id = p_analysis_id
    and analysis_version = p_version
    and status = 'processing';

  if not found then
    raise exception using errcode = '02000', message = 'Analysis is no longer claimable';
  end if;
end;
$$;

revoke all on function public.feedback_sentiment_complete(
  uuid, integer, text, numeric, jsonb, text, text
) from public, anon, authenticated;
grant execute on function public.feedback_sentiment_complete(
  uuid, integer, text, numeric, jsonb, text, text
) to service_role;

create or replace function public.feedback_sentiment_fail(
  p_analysis_id uuid,
  p_version integer,
  p_error_code text,
  p_retry_after_seconds integer default null,
  p_max_attempts integer default 3,
  p_provider text default null,
  p_model text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  attempt_value integer;
  normalized_code text := lower(coalesce(nullif(trim(p_error_code), ''), 'analysis_failed'));
  retry_seconds integer;
begin
  normalized_code := regexp_replace(normalized_code, '[^a-z0-9_]+', '_', 'g');
  normalized_code := substr(trim(both '_' from normalized_code), 1, 80);
  if length(normalized_code) < 2 then
    normalized_code := 'analysis_failed';
  end if;

  select attempt_count into attempt_value
  from public.feedback_sentiment_analyses
  where id = p_analysis_id
    and analysis_version = coalesce(p_version, 1)
    and status = 'processing'
  for update;

  if not found then
    return;
  end if;

  retry_seconds := case
    when p_retry_after_seconds is not null
      then greatest(60, least(p_retry_after_seconds, 1800))
    when attempt_value <= 1 then 60
    else 300
  end;

  if attempt_value >= greatest(1, coalesce(p_max_attempts, 3)) then
    update public.feedback_sentiment_analyses
    set status = 'failed',
        sentiment = null,
        confidence = null,
        topic_sentiments = '[]'::jsonb,
        provider = coalesce(left(nullif(trim(p_provider), ''), 80), provider),
        model = coalesce(left(nullif(trim(p_model), ''), 120), model),
        last_error_code = normalized_code,
        next_attempt_at = null,
        processing_started_at = null,
        analyzed_at = null
    where id = p_analysis_id
      and analysis_version = coalesce(p_version, 1);
  else
    update public.feedback_sentiment_analyses
    set status = 'pending',
        sentiment = null,
        confidence = null,
        topic_sentiments = '[]'::jsonb,
        provider = coalesce(left(nullif(trim(p_provider), ''), 80), provider),
        model = coalesce(left(nullif(trim(p_model), ''), 120), model),
        last_error_code = normalized_code,
        next_attempt_at = now() + make_interval(secs => retry_seconds),
        processing_started_at = null,
        analyzed_at = null
    where id = p_analysis_id
      and analysis_version = coalesce(p_version, 1);
  end if;
end;
$$;

revoke all on function public.feedback_sentiment_fail(
  uuid, integer, text, integer, integer, text, text
) from public, anon, authenticated;
grant execute on function public.feedback_sentiment_fail(
  uuid, integer, text, integer, integer, text, text
) to service_role;

create or replace function public.feedback_sentiment_retry(
  p_feedback_id uuid,
  p_version integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  feedback_row public.reservation_feedback%rowtype;
  analysis_row public.feedback_sentiment_analyses%rowtype;
  has_text boolean;
begin
  if not ((select public.is_internal_admin()) or (select public.is_external_admin())) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if coalesce(p_version, 1) < 1 then
    raise exception using errcode = '22023', message = 'Invalid analysis version';
  end if;

  select * into feedback_row
  from public.reservation_feedback
  where id = p_feedback_id;

  if not found then
    raise exception using errcode = '02000', message = 'Feedback was not found';
  end if;

  has_text := length(trim(coalesce(feedback_row.comment, ''))) > 0;

  select * into analysis_row
  from public.feedback_sentiment_analyses
  where feedback_id = p_feedback_id
    and analysis_version = coalesce(p_version, 1)
  for update;

  if not found then
    insert into public.feedback_sentiment_analyses(
      feedback_id, analysis_version, status, next_attempt_at
    )
    values (
      p_feedback_id,
      coalesce(p_version, 1),
      case when has_text then 'pending' else 'skipped' end,
      case when has_text then now() else null end
    )
    returning * into analysis_row;
  elsif has_text and analysis_row.status in ('failed','skipped') then
    update public.feedback_sentiment_analyses
    set status = 'pending',
        sentiment = null,
        confidence = null,
        topic_sentiments = '[]'::jsonb,
        provider = null,
        model = null,
        attempt_count = 0,
        next_attempt_at = now(),
        last_error_code = null,
        processing_started_at = null,
        analyzed_at = null
    where id = analysis_row.id
    returning * into analysis_row;
  elsif not has_text and analysis_row.status <> 'skipped' then
    update public.feedback_sentiment_analyses
    set status = 'skipped',
        sentiment = null,
        confidence = null,
        topic_sentiments = '[]'::jsonb,
        provider = null,
        model = null,
        next_attempt_at = null,
        last_error_code = null,
        processing_started_at = null,
        analyzed_at = null
    where id = analysis_row.id
    returning * into analysis_row;
  end if;

  return to_jsonb(analysis_row);
end;
$$;

revoke all on function public.feedback_sentiment_retry(uuid, integer)
from public, anon;
grant execute on function public.feedback_sentiment_retry(uuid, integer)
to authenticated;

create or replace function public.feedback_sentiment_backfill(
  p_limit integer default 50,
  p_facility_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_after_feedback_id uuid default null,
  p_version integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bounded_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  cursor_created_at timestamptz;
  cursor_id uuid;
  pending_count integer := 0;
  skipped_count integer := 0;
  existing_count integer := 0;
  selected_count integer := 0;
begin
  if not (select public.is_internal_admin()) then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if coalesce(p_version, 1) < 1 then
    raise exception using errcode = '22023', message = 'Invalid analysis version';
  end if;

  if p_after_feedback_id is not null then
    select created_at, id into cursor_created_at, cursor_id
    from public.reservation_feedback
    where id = p_after_feedback_id;
  end if;

  with candidates as (
    select f.id, length(trim(coalesce(f.comment, ''))) > 0 as has_text
    from public.reservation_feedback f
    where (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
      and (
        p_after_feedback_id is null
        or cursor_created_at is null
        or (f.created_at, f.id) > (cursor_created_at, cursor_id)
      )
    order by f.created_at, f.id
    limit bounded_limit
  ),
  inserted as (
    insert into public.feedback_sentiment_analyses(
      feedback_id, analysis_version, status, next_attempt_at
    )
    select id,
           coalesce(p_version, 1),
           case when has_text then 'pending' else 'skipped' end,
           case when has_text then now() else null end
    from candidates
    on conflict (feedback_id, analysis_version) do nothing
    returning status
  )
  select
    (select count(*) from candidates),
    (select count(*) from inserted where status = 'pending'),
    (select count(*) from inserted where status = 'skipped'),
    (select count(*) from candidates c
      where exists (
        select 1
        from public.feedback_sentiment_analyses a
        where a.feedback_id = c.id
          and a.analysis_version = coalesce(p_version, 1)
      )
    ) - (select count(*) from inserted)
  into selected_count, pending_count, skipped_count, existing_count;

  return jsonb_build_object(
    'selected', selected_count,
    'queued', pending_count,
    'skipped', skipped_count,
    'already_existing', greatest(existing_count, 0)
  );
end;
$$;

revoke all on function public.feedback_sentiment_backfill(
  integer, uuid, timestamptz, timestamptz, uuid, integer
) from public, anon;
grant execute on function public.feedback_sentiment_backfill(
  integer, uuid, timestamptz, timestamptz, uuid, integer
) to authenticated;

drop function if exists public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text, integer, integer
);

create or replace function public.feedback_admin_list(
  p_search text default null,
  p_facility_id uuid default null,
  p_min_rating integer default null,
  p_max_rating integer default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_sort text default 'newest',
  p_limit integer default 50,
  p_offset integer default 0,
  p_sentiment text default null,
  p_topic text default null,
  p_analysis_status text default null,
  p_needs_review boolean default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
  sort_key text := coalesce(p_sort, 'newest');
  sentiment_filter text := nullif(trim(p_sentiment), '');
  topic_filter text := nullif(trim(p_topic), '');
  status_filter text := nullif(trim(p_analysis_status), '');
begin
  if not ((select public.is_internal_admin()) or (select public.is_external_admin())) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  if sort_key not in ('newest','oldest','highest','lowest') then
    sort_key := 'newest';
  end if;
  if sentiment_filter is not null and sentiment_filter not in
     ('positive','neutral','negative','mixed','unknown') then
    raise exception using errcode = '22023', message = 'Invalid sentiment filter';
  end if;
  if status_filter is not null and status_filter not in
     ('pending','processing','completed','failed','skipped','not_analyzed') then
    raise exception using errcode = '22023', message = 'Invalid analysis-status filter';
  end if;
  if topic_filter is not null and topic_filter not in (
    'facility_cleanliness',
    'facility_condition',
    'reservation_process',
    'approval_speed',
    'staff_service',
    'payment_process',
    'equipment_availability',
    'overall_experience',
    'other'
  ) then
    raise exception using errcode = '22023', message = 'Invalid feedback-topic filter';
  end if;

  with latest as (
    select distinct on (a.feedback_id) a.*
    from public.feedback_sentiment_analyses a
    where a.analysis_version = 1
    order by a.feedback_id, a.analysis_version desc, a.created_at desc
  ),
  filtered as (
    select
      f.id,
      f.reservation_id,
      f.facility_id,
      f.user_id,
      f.rating,
      f.cleanliness_rating,
      f.condition_rating,
      f.equipment_rating,
      f.comment,
      f.created_at,
      f.updated_at,
      r.facility_name,
      r.requester_name,
      r.pricing_audience,
      (
        select min(o.starts_at)
        from public.reservation_occurrences o
        where o.request_id = f.reservation_id
          and o.lifecycle_stage = 'completed'
      ) as reservation_starts_at,
      case when a.id is null then null else jsonb_build_object(
        'id', a.id,
        'feedback_id', a.feedback_id,
        'analysis_version', a.analysis_version,
        'status', a.status,
        'sentiment', a.sentiment,
        'confidence', a.confidence,
        'topic_sentiments', a.topic_sentiments,
        'provider', a.provider,
        'model', a.model,
        'attempt_count', a.attempt_count,
        'last_error_code', a.last_error_code,
        'processing_started_at', a.processing_started_at,
        'analyzed_at', a.analyzed_at,
        'created_at', a.created_at,
        'updated_at', a.updated_at
      ) end as sentiment_analysis,
      coalesce(a.status, 'not_analyzed') as derived_analysis_status,
      coalesce(a.sentiment, 'not_analyzed') as derived_sentiment,
      (
        f.rating <= 2
        or a.sentiment = 'negative'
        or exists (
          select 1
          from jsonb_array_elements(coalesce(a.topic_sentiments, '[]'::jsonb)) topic
          where topic ->> 'sentiment' = 'negative'
        )
      ) as needs_review
    from public.reservation_feedback f
    join public.reservation_requests r on r.id = f.reservation_id
    left join latest a on a.feedback_id = f.id
    where (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_min_rating is null or f.rating >= p_min_rating)
      and (p_max_rating is null or f.rating <= p_max_rating)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
      and (nullif(trim(p_search), '') is null
        or concat_ws(' ', r.facility_name, r.requester_name, f.comment) ilike '%' || trim(p_search) || '%')
      and (sentiment_filter is null or a.sentiment = sentiment_filter)
      and (status_filter is null
        or (status_filter = 'not_analyzed' and a.id is null)
        or a.status = status_filter)
      and (topic_filter is null or exists (
        select 1
        from jsonb_array_elements(coalesce(a.topic_sentiments, '[]'::jsonb)) topic
        where topic ->> 'topic' = topic_filter
      ))
      and (p_needs_review is null or p_needs_review = (
        f.rating <= 2
        or a.sentiment = 'negative'
        or exists (
          select 1
          from jsonb_array_elements(coalesce(a.topic_sentiments, '[]'::jsonb)) topic
          where topic ->> 'sentiment' = 'negative'
        )
      ))
  ),
  page as (
    select * from filtered
    order by
      case when sort_key = 'newest' then created_at end desc,
      case when sort_key = 'oldest' then created_at end asc,
      case when sort_key = 'highest' then rating end desc,
      case when sort_key = 'lowest' then rating end asc,
      created_at desc
    limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(page)) from page), '[]'::jsonb),
    'total', (select count(*) from filtered)
  ) into result_value;
  return result_value;
end;
$$;

revoke all on function public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text,
  integer, integer, text, text, text, boolean
) from public, anon;
grant execute on function public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text,
  integer, integer, text, text, text, boolean
) to authenticated;

create or replace function public.feedback_sentiment_analytics(
  p_search text default null,
  p_facility_id uuid default null,
  p_min_rating integer default null,
  p_max_rating integer default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_sentiment text default null,
  p_topic text default null,
  p_analysis_status text default null,
  p_needs_review boolean default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
  from_value timestamptz := coalesce(p_from, now() - interval '365 days');
  to_value timestamptz := coalesce(p_to, now());
  bucket_kind text;
  sentiment_filter text := nullif(trim(p_sentiment), '');
  topic_filter text := nullif(trim(p_topic), '');
  status_filter text := nullif(trim(p_analysis_status), '');
begin
  if not ((select public.is_internal_admin()) or (select public.is_external_admin())) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;

  if sentiment_filter is not null and sentiment_filter not in
     ('positive','neutral','negative','mixed','unknown') then
    raise exception using errcode = '22023', message = 'Invalid sentiment filter';
  end if;
  if status_filter is not null and status_filter not in
     ('pending','processing','completed','failed','skipped','not_analyzed') then
    raise exception using errcode = '22023', message = 'Invalid analysis-status filter';
  end if;
  if topic_filter is not null and topic_filter not in (
    'facility_cleanliness',
    'facility_condition',
    'reservation_process',
    'approval_speed',
    'staff_service',
    'payment_process',
    'equipment_availability',
    'overall_experience',
    'other'
  ) then
    raise exception using errcode = '22023', message = 'Invalid feedback-topic filter';
  end if;

  if extract(epoch from (to_value - from_value)) / 86400.0 > 120 then
    bucket_kind := 'month';
  elsif extract(epoch from (to_value - from_value)) / 86400.0 > 31 then
    bucket_kind := 'week';
  else
    bucket_kind := 'day';
  end if;

  with latest as (
    select distinct on (a.feedback_id) a.*
    from public.feedback_sentiment_analyses a
    where a.analysis_version = 1
    order by a.feedback_id, a.analysis_version desc, a.created_at desc
  ),
  base as (
    select
      f.id,
      f.facility_id,
      fac.name as facility_name,
      f.rating,
      f.comment,
      f.created_at,
      a.id as analysis_id,
      a.status,
      a.sentiment,
      a.confidence,
      a.topic_sentiments,
      (
        f.rating <= 2
        or a.sentiment = 'negative'
        or exists (
          select 1
          from jsonb_array_elements(coalesce(a.topic_sentiments, '[]'::jsonb)) topic
          where topic ->> 'sentiment' = 'negative'
        )
      ) as needs_review,
      (
        (f.rating >= 4 and a.sentiment = 'negative')
        or (f.rating <= 2 and a.sentiment = 'positive')
      ) as rating_mismatch
    from public.reservation_feedback f
    join public.reservation_requests r on r.id = f.reservation_id
    join public.facilities fac on fac.id = f.facility_id
    left join latest a on a.feedback_id = f.id
    where (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_min_rating is null or f.rating >= p_min_rating)
      and (p_max_rating is null or f.rating <= p_max_rating)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
      and (nullif(trim(p_search), '') is null
        or concat_ws(' ', r.facility_name, r.requester_name, f.comment) ilike '%' || trim(p_search) || '%')
      and (sentiment_filter is null or a.sentiment = sentiment_filter)
      and (status_filter is null
        or (status_filter = 'not_analyzed' and a.id is null)
        or a.status = status_filter)
      and (topic_filter is null or exists (
        select 1
        from jsonb_array_elements(coalesce(a.topic_sentiments, '[]'::jsonb)) topic
        where topic ->> 'topic' = topic_filter
      ))
      and (p_needs_review is null or p_needs_review = (
        f.rating <= 2
        or a.sentiment = 'negative'
        or exists (
          select 1
          from jsonb_array_elements(coalesce(a.topic_sentiments, '[]'::jsonb)) topic
          where topic ->> 'sentiment' = 'negative'
        )
      ))
  ),
  counts as (
    select
      count(*)::int as total_feedback,
      count(*) filter (where length(trim(coalesce(comment, ''))) > 0)::int as written_feedback,
      count(*) filter (where status = 'completed')::int as classified_feedback,
      count(*) filter (where status = 'pending')::int as pending_count,
      count(*) filter (where status = 'processing')::int as processing_count,
      count(*) filter (where status = 'failed')::int as failed_count,
      count(*) filter (where status = 'skipped')::int as skipped_count,
      count(*) filter (where analysis_id is null
        and length(trim(coalesce(comment, ''))) > 0)::int as not_analyzed_count,
      count(*) filter (where sentiment = 'positive')::int as positive_count,
      count(*) filter (where sentiment = 'neutral')::int as neutral_count,
      count(*) filter (where sentiment = 'negative')::int as negative_count,
      count(*) filter (where sentiment = 'mixed')::int as mixed_count,
      count(*) filter (where sentiment = 'unknown')::int as unknown_count,
      count(*) filter (where needs_review)::int as needs_review_count,
      count(*) filter (where rating_mismatch)::int as rating_mismatch_count,
      round(avg(rating)::numeric, 2) as average_rating
    from base
  ),
  trend as (
    select
      date_trunc(bucket_kind, created_at) as bucket_start,
      count(*) filter (where sentiment = 'positive')::int as positive,
      count(*) filter (where sentiment = 'neutral')::int as neutral,
      count(*) filter (where sentiment = 'negative')::int as negative,
      count(*) filter (where sentiment = 'mixed')::int as mixed,
      count(*) filter (
        where sentiment in ('positive','neutral','negative','mixed')
      )::int as classified,
      round(avg(rating)::numeric, 2) as average_rating
    from base
    where status = 'completed'
      and sentiment in ('positive','neutral','negative','mixed')
    group by date_trunc(bucket_kind, created_at)
    order by bucket_start desc
    limit 24
  ),
  facility as (
    select
      facility_id,
      facility_name,
      count(*) filter (where sentiment in ('positive','neutral','negative','mixed'))::int as classified,
      count(*) filter (where sentiment = 'positive')::int as positive,
      count(*) filter (where sentiment = 'neutral')::int as neutral,
      count(*) filter (where sentiment = 'negative')::int as negative,
      count(*) filter (where sentiment = 'mixed')::int as mixed,
      count(*) filter (where needs_review)::int as needs_review,
      round(avg(rating)::numeric, 2) as average_rating
    from base
    where status = 'completed'
      and sentiment in ('positive','neutral','negative','mixed')
    group by facility_id, facility_name
    having count(*) filter (where sentiment in ('positive','neutral','negative','mixed')) >= 3
    order by
      (
        count(*) filter (where sentiment = 'negative')::numeric
        / nullif(count(*) filter (where sentiment in ('positive','neutral','negative','mixed')), 0)
      ) desc,
      count(*) filter (where sentiment = 'negative') desc,
      facility_name
    limit 8
  ),
  complaint as (
    select
      topic ->> 'topic' as topic,
      count(*)::int as count,
      count(distinct b.facility_id)::int as facility_count
    from base b
    cross join lateral jsonb_array_elements(coalesce(b.topic_sentiments, '[]'::jsonb)) topic
    where topic ->> 'sentiment' = 'negative'
    group by topic ->> 'topic'
    having count(*) >= 2
    order by count(*) desc, topic ->> 'topic'
    limit 8
  )
  select jsonb_build_object(
    'total_feedback', c.total_feedback,
    'written_feedback', c.written_feedback,
    'classified_feedback', c.classified_feedback,
    'pending', c.pending_count,
    'processing', c.processing_count,
    'failed', c.failed_count,
    'skipped', c.skipped_count,
    'not_analyzed', c.not_analyzed_count,
    'average_rating', c.average_rating,
    'positive', c.positive_count,
    'neutral', c.neutral_count,
    'negative', c.negative_count,
    'mixed', c.mixed_count,
    'unknown', c.unknown_count,
    'needs_review', c.needs_review_count,
    'rating_mismatch', c.rating_mismatch_count,
    'trend_bucket', bucket_kind,
    'trend', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.bucket_start)
      from trend t
    ), '[]'::jsonb),
    'facilities', coalesce((
      select jsonb_agg(to_jsonb(f))
      from facility f
    ), '[]'::jsonb),
    'complaints', coalesce((
      select jsonb_agg(to_jsonb(cm))
      from complaint cm
    ), '[]'::jsonb)
  )
  into result_value
  from counts c;

  return coalesce(result_value, jsonb_build_object(
    'total_feedback', 0,
    'written_feedback', 0,
    'classified_feedback', 0,
    'pending', 0,
    'processing', 0,
    'failed', 0,
    'skipped', 0,
    'not_analyzed', 0,
    'average_rating', null,
    'positive', 0,
    'neutral', 0,
    'negative', 0,
    'mixed', 0,
    'unknown', 0,
    'needs_review', 0,
    'rating_mismatch', 0,
    'trend_bucket', bucket_kind,
    'trend', '[]'::jsonb,
    'facilities', '[]'::jsonb,
    'complaints', '[]'::jsonb
  ));
end;
$$;

revoke all on function public.feedback_sentiment_analytics(
  text, uuid, integer, integer, timestamptz, timestamptz,
  text, text, text, boolean
) from public, anon;
grant execute on function public.feedback_sentiment_analytics(
  text, uuid, integer, integer, timestamptz, timestamptz,
  text, text, text, boolean
) to authenticated;

create or replace function public.invoke_feedback_sentiment_worker()
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
    execute
      'select decrypted_secret from vault.decrypted_secrets where name = $1'
      using 'smartreserve_function_url'
      into function_base_url;
    execute
      'select decrypted_secret from vault.decrypted_secrets where name = $1'
      using 'smartreserve_sentiment_worker_key'
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
        trim(trailing '/' from function_base_url) || '/functions/v1/feedback-sentiment',
        jsonb_build_object(
          'Content-Type', 'application/json',
          'x-smartreserve-worker-key', worker_key
        ),
        jsonb_build_object('source', 'pg_cron', 'scheduled_at', now())
      into request_id;
  exception
    when invalid_schema_name or undefined_function then
      return null;
  end;

  return request_id;
end;
$$;

revoke all on function public.invoke_feedback_sentiment_worker()
from public, anon, authenticated;
grant execute on function public.invoke_feedback_sentiment_worker()
to service_role;

do $$
begin
  begin
    create extension if not exists pg_net;
  exception
    when feature_not_supported or insufficient_privilege or undefined_file then
      raise notice 'pg_net is not available; configure it before enabling feedback sentiment scheduling.';
  end;

  begin
    create extension if not exists pg_cron;
  exception
    when feature_not_supported or insufficient_privilege or undefined_file then
      raise notice 'pg_cron is not available; configure it before enabling feedback sentiment scheduling.';
  end;

  begin
    if exists (select 1 from pg_namespace where nspname = 'cron') then
      if not exists (
        select 1
        from cron.job
        where jobname = 'smartreserve-feedback-sentiment'
      ) then
        perform cron.schedule(
          'smartreserve-feedback-sentiment',
          '* * * * *',
          'select public.invoke_feedback_sentiment_worker();'
        );
      end if;
    end if;
  exception
    when invalid_schema_name or undefined_table or undefined_function
      or insufficient_privilege then
      raise notice 'feedback sentiment Cron scheduling was skipped; configure pg_cron manually before enabling the worker.';
  end;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'feedback_sentiment_analyses'
  ) then
    alter publication supabase_realtime
      add table public.feedback_sentiment_analyses;
  end if;
exception
  when undefined_object then
    null;
end $$;

notify pgrst, 'reload schema';
