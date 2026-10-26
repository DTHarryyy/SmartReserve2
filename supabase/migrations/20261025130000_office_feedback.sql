-- Office service feedback: renters rate the reservation office itself (how
-- quickly and helpfully it handled their request, and how clear the process
-- was), independent of any one facility or reservation. Administrators read
-- it in Feedback > Office service.

create table if not exists public.office_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  overall_rating smallint not null check (overall_rating between 1 and 5),
  responsiveness_rating smallint check (responsiveness_rating between 1 and 5),
  helpfulness_rating smallint check (helpfulness_rating between 1 and 5),
  clarity_rating smallint check (clarity_rating between 1 and 5),
  comment text not null default '' check (length(comment) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists office_feedback_created_idx
  on public.office_feedback(created_at desc);
create index if not exists office_feedback_user_idx
  on public.office_feedback(user_id, created_at desc);

alter table public.office_feedback enable row level security;
revoke all on public.office_feedback from public, anon, authenticated;
grant select on public.office_feedback to authenticated;

drop policy if exists office_feedback_read on public.office_feedback;
create policy office_feedback_read on public.office_feedback
for select to authenticated
using (user_id = (select auth.uid()) or (select public.is_admin()));

-- One rating per person per day keeps the averages honest without asking
-- people to come back.
create or replace function public.submit_office_feedback(
  p_overall_rating integer,
  p_responsiveness_rating integer default null,
  p_helpfulness_rating integer default null,
  p_clarity_rating integer default null,
  p_comment text default ''
) returns public.office_feedback
language plpgsql
security definer
set search_path = public
as $$
declare
  row_value public.office_feedback%rowtype;
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and account_status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'Please sign in again';
  end if;
  if public.is_admin() then
    raise exception using errcode = '42501',
      message = 'Office feedback comes from the people the office serves';
  end if;
  if exists (
    select 1 from public.office_feedback
    where user_id = auth.uid() and created_at > now() - interval '24 hours'
  ) then
    raise exception using errcode = '22023',
      message = 'You already rated the office today. Thank you!';
  end if;

  insert into public.office_feedback(
    user_id, overall_rating, responsiveness_rating, helpfulness_rating,
    clarity_rating, comment
  ) values (
    auth.uid(), p_overall_rating, p_responsiveness_rating, p_helpfulness_rating,
    p_clarity_rating, trim(coalesce(p_comment, ''))
  ) returning * into row_value;

  return row_value;
end;
$$;

revoke all on function public.submit_office_feedback(integer, integer, integer, integer, text)
  from public, anon;
grant execute on function public.submit_office_feedback(integer, integer, integer, integer, text)
  to authenticated;

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
    'support_tickets',
    'support_ticket_replies',
    'office_feedback',
    'app_notifications'
  ]::text[];
$$;

revoke all on function public.system_backup_tables() from public, anon, authenticated;
grant execute on function public.system_backup_tables() to authenticated, service_role;

notify pgrst, 'reload schema';
