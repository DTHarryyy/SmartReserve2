-- Technical support: renters and administrators file tickets (category,
-- subject, message, optional screenshot); administrators answer them from
-- the Support queue and move them through open → in progress → resolved →
-- closed. Every new ticket, reply and status change lands in
-- app_notifications, so it is also pushed and emailed like any other
-- notification.
--
-- All writes go through the RPCs below so the notification fan-out cannot be
-- skipped; clients only read the tables, through RLS.

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  category text not null
    check (category in ('account','reservation','payment','bug','other')),
  subject text not null check (length(trim(subject)) between 3 and 120),
  message text not null check (length(trim(message)) between 10 and 2000),
  attachment_path text
    check (attachment_path is null or (length(attachment_path) between 3 and 300 and attachment_path !~ '\.\.')),
  status text not null default 'open'
    check (status in ('open','in_progress','resolved','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists support_tickets_requester_idx
  on public.support_tickets(requester_id, last_activity_at desc);
create index if not exists support_tickets_status_idx
  on public.support_tickets(status, last_activity_at desc);

create table if not exists public.support_ticket_replies (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null,
  author_name text not null default '',
  from_admin boolean not null default false,
  message text not null check (length(trim(message)) between 3 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists support_ticket_replies_ticket_idx
  on public.support_ticket_replies(ticket_id, created_at);

-- Lets a notification open the exact ticket.
alter table public.app_notifications
  add column if not exists support_ticket_id uuid
    references public.support_tickets(id) on delete cascade;
create index if not exists app_notifications_support_ticket_idx
  on public.app_notifications(support_ticket_id)
  where support_ticket_id is not null;

alter table public.support_tickets enable row level security;
alter table public.support_ticket_replies enable row level security;
revoke all on public.support_tickets, public.support_ticket_replies
  from public, anon, authenticated;
grant select on public.support_tickets, public.support_ticket_replies
  to authenticated;

drop policy if exists support_tickets_read on public.support_tickets;
create policy support_tickets_read on public.support_tickets
for select to authenticated
using (requester_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists support_ticket_replies_read on public.support_ticket_replies;
create policy support_ticket_replies_read on public.support_ticket_replies
for select to authenticated
using (exists (
  select 1 from public.support_tickets t
  where t.id = ticket_id
    and (t.requester_id = (select auth.uid()) or (select public.is_admin()))
));

-- Screenshots: private bucket, <requester id>/<file>. The owner uploads and
-- reads their own; administrators read all.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('support-attachments', 'support-attachments', false, 5242880,
  array['image/jpeg', 'image/png'])
on conflict (id) do update
set public = false,
    file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png'];

drop policy if exists support_attachments_insert_own on storage.objects;
create policy support_attachments_insert_own on storage.objects
for insert to authenticated
with check (
  bucket_id = 'support-attachments'
  and split_part(name, '/', 1) = (select auth.uid())::text
);

drop policy if exists support_attachments_read on storage.objects;
create policy support_attachments_read on storage.objects
for select to authenticated
using (
  bucket_id = 'support-attachments'
  and (split_part(name, '/', 1) = (select auth.uid())::text
       or (select public.is_admin()))
);

create or replace function public._support_actor()
returns table(id uuid, name text, is_admin boolean)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, coalesce(nullif(trim(p.full_name), ''), p.email),
    p.role in ('internal_admin','external_admin')
  from public.profiles p
  where p.id = auth.uid() and p.account_status = 'active';
$$;

revoke all on function public._support_actor() from public, anon, authenticated;

create or replace function public.create_support_ticket(
  p_category text,
  p_subject text,
  p_message text,
  p_attachment_path text default null
) returns public.support_tickets
language plpgsql
security definer
set search_path = public
as $$
declare
  actor record;
  ticket public.support_tickets%rowtype;
  attachment text := nullif(trim(coalesce(p_attachment_path, '')), '');
begin
  select * into actor from public._support_actor();
  if actor.id is null then
    raise exception using errcode = '42501', message = 'Please sign in again';
  end if;
  if attachment is not null and split_part(attachment, '/', 1) <> actor.id::text then
    raise exception using errcode = '22023', message = 'Attach a screenshot you uploaded';
  end if;
  -- Five open tickets is plenty; more is almost always a double submit.
  if (select count(*) from public.support_tickets
      where requester_id = actor.id and status in ('open','in_progress')) >= 5 then
    raise exception using errcode = '22023',
      message = 'You already have 5 open tickets. Add to one of those instead';
  end if;

  insert into public.support_tickets(requester_id, category, subject, message, attachment_path)
  values (actor.id, p_category, trim(p_subject), trim(p_message), attachment)
  returning * into ticket;

  -- Internal Admins own the support queue.
  insert into public.app_notifications(recipient_id, support_ticket_id, kind, title, body)
  select p.id, ticket.id, 'support_ticket_new',
    'New support ticket',
    actor.name || ': ' || ticket.subject
  from public.profiles p
  where p.role = 'internal_admin' and p.account_status = 'active' and p.id <> actor.id;

  return ticket;
end;
$$;

create or replace function public.reply_support_ticket(
  p_ticket_id uuid,
  p_message text
) returns public.support_ticket_replies
language plpgsql
security definer
set search_path = public
as $$
declare
  actor record;
  ticket public.support_tickets%rowtype;
  reply public.support_ticket_replies%rowtype;
begin
  select * into actor from public._support_actor();
  if actor.id is null then
    raise exception using errcode = '42501', message = 'Please sign in again';
  end if;
  select * into ticket from public.support_tickets where id = p_ticket_id for update;
  if ticket.id is null or (ticket.requester_id <> actor.id and not actor.is_admin) then
    raise exception using errcode = 'P0002', message = 'Support ticket not found';
  end if;
  if ticket.status = 'closed' then
    raise exception using errcode = '22023',
      message = 'This ticket is closed. Open a new ticket instead';
  end if;

  insert into public.support_ticket_replies(ticket_id, author_id, author_name, from_admin, message)
  values (ticket.id, actor.id, actor.name, actor.is_admin and ticket.requester_id <> actor.id,
    trim(p_message))
  returning * into reply;

  update public.support_tickets
  set last_activity_at = now(),
      updated_at = now(),
      -- A renter writing back reopens a resolved ticket; an admin answering
      -- an open one picks it up.
      status = case
        when not reply.from_admin and status = 'resolved' then 'open'
        when reply.from_admin and status = 'open' then 'in_progress'
        else status
      end,
      resolved_at = case
        when not reply.from_admin and status = 'resolved' then null
        else resolved_at
      end
  where id = ticket.id;

  if reply.from_admin then
    insert into public.app_notifications(recipient_id, support_ticket_id, kind, title, body)
    values (ticket.requester_id, ticket.id, 'support_reply',
      'Support replied: ' || ticket.subject, left(reply.message, 280));
  else
    insert into public.app_notifications(recipient_id, support_ticket_id, kind, title, body)
    select distinct r.author_id, ticket.id, 'support_reply',
      'New reply on: ' || ticket.subject, left(reply.message, 280)
    from public.support_ticket_replies r
    join public.profiles p on p.id = r.author_id
    where r.ticket_id = ticket.id and r.from_admin
      and p.account_status = 'active' and r.author_id <> actor.id;
    -- Nobody has answered yet: tell the queue owners again.
    if not found then
      insert into public.app_notifications(recipient_id, support_ticket_id, kind, title, body)
      select p.id, ticket.id, 'support_reply',
        'New reply on: ' || ticket.subject, left(reply.message, 280)
      from public.profiles p
      where p.role = 'internal_admin' and p.account_status = 'active' and p.id <> actor.id;
    end if;
  end if;

  return reply;
end;
$$;

create or replace function public.set_support_ticket_status(
  p_ticket_id uuid,
  p_status text
) returns public.support_tickets
language plpgsql
security definer
set search_path = public
as $$
declare
  actor record;
  ticket public.support_tickets%rowtype;
begin
  select * into actor from public._support_actor();
  if actor.id is null then
    raise exception using errcode = '42501', message = 'Please sign in again';
  end if;
  if p_status not in ('open','in_progress','resolved','closed') then
    raise exception using errcode = '22023', message = 'Invalid ticket status';
  end if;
  select * into ticket from public.support_tickets where id = p_ticket_id for update;
  if ticket.id is null or (ticket.requester_id <> actor.id and not actor.is_admin) then
    raise exception using errcode = 'P0002', message = 'Support ticket not found';
  end if;
  -- Requesters may only close their own ticket (or reopen it while it is
  -- not yet closed); everything else is the administrators' call.
  if not actor.is_admin and not (
    p_status = 'closed'
    or (p_status = 'open' and ticket.status = 'resolved')
  ) then
    raise exception using errcode = '42501',
      message = 'Only administrators can change this ticket''s status';
  end if;
  if ticket.status = p_status then
    return ticket;
  end if;

  update public.support_tickets
  set status = p_status,
      updated_at = now(),
      last_activity_at = now(),
      resolved_at = case when p_status in ('resolved','closed') then coalesce(resolved_at, now()) else null end
  where id = ticket.id
  returning * into ticket;

  if actor.id <> ticket.requester_id then
    insert into public.app_notifications(recipient_id, support_ticket_id, kind, title, body)
    values (ticket.requester_id, ticket.id, 'support_status',
      'Ticket ' || replace(p_status, '_', ' ') || ': ' || ticket.subject,
      case p_status
        when 'resolved' then 'Support marked your ticket resolved. Reply if you still need help.'
        when 'closed' then 'Support closed your ticket.'
        when 'in_progress' then 'Support is working on your ticket.'
        else 'Your ticket was reopened.'
      end);
  end if;

  return ticket;
end;
$$;

revoke all on function public.create_support_ticket(text, text, text, text) from public, anon;
revoke all on function public.reply_support_ticket(uuid, text) from public, anon;
revoke all on function public.set_support_ticket_status(uuid, text) from public, anon;
grant execute on function public.create_support_ticket(text, text, text, text) to authenticated;
grant execute on function public.reply_support_ticket(uuid, text) to authenticated;
grant execute on function public.set_support_ticket_status(uuid, text) to authenticated;

-- Tickets and their threads are operational records, restored with the rest.
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
    'app_notifications'
  ]::text[];
$$;

revoke all on function public.system_backup_tables() from public, anon, authenticated;
grant execute on function public.system_backup_tables() to authenticated, service_role;

notify pgrst, 'reload schema';
