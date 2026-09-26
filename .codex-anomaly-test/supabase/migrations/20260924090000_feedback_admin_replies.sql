-- Admin replies to renter feedback.
--
-- Renters have been able to leave a review since
-- 20260823090000_reservation_feedback_and_loyalty.sql, and both admin lanes
-- have been able to read every review since
-- 20260828120000_global_external_admin_feedback.sql. Neither lane has ever
-- had a way to answer one -- the review lands in the admin console and the
-- renter never hears back. This adds a single reply per review.
--
-- Design decisions worth reading before touching this file:
--
-- 1. Read access stays global (either admin lane can see any review, per
--    the migrations above), but the WRITE is lane-scoped: an internal_admin
--    may only reply on an internal-lane reservation, an external_admin only
--    on an external-lane one. public.can_manage_reservation(reservation_id)
--    already encodes exactly that rule (admin_lane(caller) = r.admin_lane),
--    so it is reused rather than re-derived here.
--
-- 2. One reply per review, edited in place via upsert (unique on
--    feedback_id) rather than a thread. The product decision is one-way
--    admin to renter, not a conversation; a renter cannot write to this
--    table at all (see grants below). admin_id/admin_name/admin_lane are
--    snapshotted at write time -- the same pattern reservation_events uses
--    for actor_name/actor_role -- so history reads correctly even if the
--    admin's name or lane changes later.
--
-- 3. The notification is inserted directly rather than through
--    public.notify_reservation_user(), because that helper is gated on the
--    reservation_decisions preference (approve/deny noise), which has
--    nothing to do with a direct human reply to a review.
--
-- 4. Every write goes through security definer RPC reply_to_feedback().
--    The table itself grants only SELECT to authenticated -- a renter can
--    read their own reply but cannot forge or edit one directly.
--
-- 5. feedback_admin_list() has THREE prior definitions in this repo. The
--    live, client-facing one is the 13-argument overload added by
--    20260829100000_feedback_sentiment_analysis.sql (the Flutter client
--    always calls it with all 13 named params -- see feedbackEntries() in
--    lib/backend/supabase_service.dart). That is the one replaced below,
--    verbatim plus the reply/lane projection. The older 9-arg overload from
--    20260828120000_global_external_admin_feedback.sql is left untouched;
--    it is dead but harmless, and dropping it is a separate concern.

create table if not exists public.reservation_feedback_replies (
  id uuid primary key default gen_random_uuid(),
  feedback_id uuid not null unique
    references public.reservation_feedback(id) on delete cascade,
  reservation_id uuid not null
    references public.reservation_requests(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  admin_id uuid not null references public.profiles(id) on delete restrict,
  admin_name text not null,
  admin_lane text not null check (admin_lane in ('internal','external')),
  message text not null check (length(trim(message)) between 3 and 1000),
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists reservation_feedback_replies_recipient_idx
  on public.reservation_feedback_replies(recipient_id, created_at desc);

drop trigger if exists reservation_feedback_replies_touch
  on public.reservation_feedback_replies;
create trigger reservation_feedback_replies_touch
before update on public.reservation_feedback_replies
for each row execute procedure public.set_updated_at();

alter table public.reservation_feedback_replies enable row level security;
revoke all on public.reservation_feedback_replies from public, anon, authenticated;
grant select on public.reservation_feedback_replies to authenticated;

drop policy if exists reservation_feedback_replies_read
  on public.reservation_feedback_replies;
create policy reservation_feedback_replies_read
on public.reservation_feedback_replies for select to authenticated
using (
  recipient_id = (select auth.uid())
  or (select public.is_internal_admin())
  or (select public.is_external_admin())
);

-- Repeat-safe notification, mirroring app_notifications_single_low_rating_idx
-- (20260823090000_reservation_feedback_and_loyalty.sql).
create unique index if not exists app_notifications_single_feedback_reply_idx
  on public.app_notifications(recipient_id, request_id, kind)
  where kind = 'feedback_reply';

create or replace function public.reply_to_feedback(
  p_feedback_id uuid,
  p_message text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_lane text := public.admin_lane();
  caller_name text;
  feedback_row public.reservation_feedback%rowtype;
  request_row public.reservation_requests%rowtype;
  clean_message text := trim(coalesce(p_message, ''));
  reply_row public.reservation_feedback_replies%rowtype;
begin
  if caller_lane is null then
    raise exception using errcode = '42501',
      message = 'Administrator access required';
  end if;

  select * into feedback_row
  from public.reservation_feedback
  where id = p_feedback_id;
  if not found then
    raise exception using errcode = '22023', message = 'Feedback not found';
  end if;

  select * into request_row
  from public.reservation_requests
  where id = feedback_row.reservation_id;
  if not found or not public.can_manage_reservation(request_row.id) then
    raise exception using errcode = '42501',
      message = 'This reservation belongs to another administrator lane';
  end if;

  if length(clean_message) < 3 or length(clean_message) > 1000 then
    raise exception using errcode = '22023',
      message = 'Reply must be between 3 and 1000 characters';
  end if;

  select full_name into caller_name
  from public.profiles
  where id = auth.uid();

  insert into public.reservation_feedback_replies(
    feedback_id, reservation_id, recipient_id, admin_id, admin_name,
    admin_lane, message
  )
  values (
    feedback_row.id, request_row.id, feedback_row.user_id, auth.uid(),
    coalesce(caller_name, ''), caller_lane, clean_message
  )
  on conflict (feedback_id) do update
    set message = excluded.message,
        admin_id = excluded.admin_id,
        admin_name = excluded.admin_name,
        admin_lane = excluded.admin_lane,
        revision = reservation_feedback_replies.revision + 1
  returning * into reply_row;

  insert into public.app_notifications(recipient_id, request_id, kind, title, body)
  values (
    feedback_row.user_id, request_row.id, 'feedback_reply',
    'Reply to your review of ' || request_row.facility_name,
    left(clean_message, 200)
  )
  on conflict (recipient_id, request_id, kind)
    where kind = 'feedback_reply'
    do update set
      title = excluded.title,
      body = excluded.body,
      created_at = now(),
      read_at = null;

  return to_jsonb(reply_row);
end;
$$;

revoke all on function public.reply_to_feedback(uuid, text) from public, anon;
grant execute on function public.reply_to_feedback(uuid, text) to authenticated;

-- Surface the reply in the admin feedback list. This replaces the LIVE
-- 13-arg overload (see note 5 above), verbatim from
-- 20260829100000_feedback_sentiment_analysis.sql, plus a left join for the
-- reply and the reservation's admin_lane projected into the filtered CTE.
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
      r.admin_lane as reservation_admin_lane,
      fr.message as reply_message,
      fr.admin_name as reply_admin_name,
      fr.updated_at as reply_updated_at,
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
    left join public.reservation_feedback_replies fr on fr.feedback_id = f.id
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

notify pgrst, 'reload schema';
