create extension if not exists btree_gist;

alter table public.facilities
  add column if not exists max_duration_minutes integer not null default 240
    check (max_duration_minutes between 30 and 1440),
  add column if not exists advance_booking_days integer not null default 30
    check (advance_booking_days between 1 and 365),
  add column if not exists booking_buffer_minutes integer not null default 15
    check (booking_buffer_minutes between 0 and 240);

update public.facilities
set max_duration_minutes = greatest(30, coalesce((regexp_match(max_duration, '(\d+)'))[1]::integer * 60, 240)),
    advance_booking_days = greatest(1, coalesce((regexp_match(advance_booking, '(\d+)'))[1]::integer, 30)),
    booking_buffer_minutes = greatest(0, coalesce((regexp_match(booking_buffer, '(\d+)'))[1]::integer, 15));

create table if not exists public.reservation_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete restrict,
  facility_id uuid not null references public.facilities(id) on delete restrict,
  requester_name text not null,
  requester_role text not null,
  requester_unit text not null default '',
  facility_name text not null,
  facility_building text not null default '',
  facility_room text not null default '',
  facility_capacity integer not null,
  purpose text not null check (length(trim(purpose)) between 3 and 1000),
  headcount integer not null check (headcount between 1 and 5000),
  status text not null default 'pending'
    check (status in ('pending','approved','changes_requested','declined','cancelled','expired')),
  held_for_verification boolean not null default false,
  recurrence text not null default 'none' check (recurrence in ('none','weekly')),
  decision_reason text,
  decided_by uuid references public.profiles(id) on delete set null,
  decided_by_name text,
  decided_at timestamptz,
  payment_amount_centavos integer not null default 0 check (payment_amount_centavos >= 0),
  payment_status text not null default 'not_required'
    check (payment_status in ('not_required','quoted','authorized','captured','voided')),
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists reservation_requests_requester_idx
  on public.reservation_requests(requester_id, created_at desc);
create index if not exists reservation_requests_queue_idx
  on public.reservation_requests(status, held_for_verification, created_at);

create table if not exists public.reservation_occurrences (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  facility_id uuid not null references public.facilities(id) on delete restrict,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  buffer_minutes integer not null default 0 check (buffer_minutes between 0 and 240),
  booking_state text not null default 'requested'
    check (booking_state in ('requested','booked','changes_requested','cancelled','expired','bumped')),
  lifecycle_stage text not null default 'booked'
    check (lifecycle_stage in ('booked','checked_in','completed','no_show')),
  proposed_starts_at timestamptz,
  proposed_ends_at timestamptz,
  exception_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (starts_at < ends_at),
  check ((proposed_starts_at is null) = (proposed_ends_at is null)),
  check (proposed_starts_at is null or proposed_starts_at < proposed_ends_at)
);

alter table public.reservation_occurrences
  add column if not exists blocked_window tstzrange not null default 'empty'::tstzrange;

create or replace function public.set_reservation_blocked_window()
returns trigger language plpgsql as $$
begin
  new.blocked_window := tstzrange(
    new.starts_at - (new.buffer_minutes * interval '1 minute'),
    new.ends_at + (new.buffer_minutes * interval '1 minute'),
    '[)'
  );
  return new;
end;
$$;

drop trigger if exists reservation_occurrences_blocked_window
  on public.reservation_occurrences;
create trigger reservation_occurrences_blocked_window
before insert or update of starts_at,ends_at,buffer_minutes
on public.reservation_occurrences
for each row execute procedure public.set_reservation_blocked_window();

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'reservation_occurrences_no_overlap'
  ) then
    alter table public.reservation_occurrences
      add constraint reservation_occurrences_no_overlap
      exclude using gist (facility_id with =, blocked_window with &&)
      where (booking_state = 'booked');
  end if;
end $$;

create index if not exists reservation_occurrences_request_idx
  on public.reservation_occurrences(request_id, starts_at);
create index if not exists reservation_occurrences_schedule_idx
  on public.reservation_occurrences(facility_id, starts_at, ends_at);

create table if not exists public.reservation_attachments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/jpeg','image/png','application/pdf')),
  byte_size integer not null check (byte_size between 1 and 10485760),
  created_at timestamptz not null default now()
);

create table if not exists public.reservation_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  occurrence_id uuid references public.reservation_occurrences(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_name text not null,
  actor_role text not null,
  action text not null,
  reason text,
  details jsonb not null default '{}'::jsonb,
  material boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists reservation_events_request_idx
  on public.reservation_events(request_id, created_at desc);

create table if not exists public.app_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  request_id uuid references public.reservation_requests(id) on delete cascade,
  event_id uuid references public.reservation_events(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists app_notifications_recipient_idx
  on public.app_notifications(recipient_id, read_at, created_at desc);
create unique index if not exists app_notifications_single_reminder_idx
  on public.app_notifications(recipient_id,request_id,kind)
  where kind='reservation_reminder';

create table if not exists public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  reservation_decisions boolean not null default true,
  day_before_reminders boolean not null default true,
  new_facilities boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists public.reservation_action_journal (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles(id) on delete cascade,
  idempotency_key uuid not null,
  action text not null,
  request_ids uuid[] not null,
  before_requests jsonb not null,
  before_occurrences jsonb not null,
  after_versions jsonb not null default '{}'::jsonb,
  undo_until timestamptz not null default (now() + interval '8 seconds'),
  undone_at timestamptz,
  created_at timestamptz not null default now(),
  unique(actor_id, idempotency_key)
);

create or replace function public.touch_reservation_row()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  if tg_table_name = 'reservation_requests' then
    new.version = old.version + 1;
  end if;
  return new;
end;
$$;

drop trigger if exists reservation_requests_touch on public.reservation_requests;
create trigger reservation_requests_touch before update on public.reservation_requests
for each row execute procedure public.touch_reservation_row();
drop trigger if exists reservation_occurrences_touch on public.reservation_occurrences;
create trigger reservation_occurrences_touch before update on public.reservation_occurrences
for each row execute procedure public.touch_reservation_row();

create or replace function public.reservation_is_admin(target_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin(target_id);
$$;

create or replace function public.reservation_event(
  p_request_id uuid,
  p_action text,
  p_reason text default null,
  p_details jsonb default '{}'::jsonb,
  p_occurrence_id uuid default null,
  p_material boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  actor public.profiles%rowtype;
  event_id uuid;
begin
  select * into actor from public.profiles where id = auth.uid();
  insert into public.reservation_events(
    request_id, occurrence_id, actor_id, actor_name, actor_role,
    action, reason, details, material
  ) values (
    p_request_id, p_occurrence_id, auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email, 'the system'),
    coalesce(actor.role, 'system'), p_action, nullif(trim(p_reason), ''),
    coalesce(p_details, '{}'::jsonb), p_material
  ) returning id into event_id;
  return event_id;
end;
$$;

create or replace function public.notify_reservation_user(
  p_request_id uuid, p_event_id uuid, p_kind text, p_title text, p_body text
) returns void
language sql security definer set search_path = public as $$
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select requester_id, id, p_event_id, p_kind, p_title, p_body
  from public.reservation_requests
  where id = p_request_id
    and coalesce((select reservation_decisions from public.notification_preferences
                  where user_id = requester_id), true);
$$;

create or replace function public.submit_reservation(
  p_request_id uuid,
  p_facility_id uuid,
  p_purpose text,
  p_headcount integer,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_payment_amount_centavos integer default 0
) returns public.reservation_requests
language plpgsql security definer set search_path = public, storage as $$
declare
  profile public.profiles%rowtype;
  facility public.facilities%rowtype;
  result public.reservation_requests%rowtype;
  held boolean;
  payment text;
  attachment jsonb;
  event_id uuid;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'Sign in required'; end if;
  select * into profile from public.profiles where id = auth.uid() for update;
  if profile.id is null or profile.account_status <> 'active' then
    raise exception using errcode = '42501', message = 'This account cannot submit reservations';
  end if;
  if profile.role in ('internal_admin','external_admin') then
    raise exception using errcode = '22023', message = 'Use a member account to submit a reservation';
  end if;
  select * into facility from public.facilities
    where id = p_facility_id and archived_at is null and public_listing for share;
  if facility.id is null then raise exception using errcode = 'P0002', message = 'Facility not found'; end if;
  if cardinality(p_starts_at) is null or cardinality(p_starts_at) not between 1 and 12
     or cardinality(p_starts_at) <> cardinality(p_ends_at) then
    raise exception using errcode = '22023', message = 'Provide between one and twelve valid occurrences';
  end if;
  if jsonb_array_length(coalesce(p_attachment_metadata, '[]'::jsonb)) > 3 then
    raise exception using errcode = '22023', message = 'A maximum of three supporting files is allowed';
  end if;
  held := profile.verification_status = 'pending';
  payment := case when profile.verification_status = 'verified' then 'not_required' else 'quoted' end;
  insert into public.reservation_requests(
    id, requester_id, facility_id, requester_name, requester_role, requester_unit,
    facility_name, facility_building, facility_room, facility_capacity,
    purpose, headcount, held_for_verification, recurrence,
    payment_amount_centavos, payment_status
  ) values (
    p_request_id, profile.id, facility.id, coalesce(nullif(profile.full_name,''), profile.email),
    profile.role, coalesce(profile.unit,''), facility.name::text, facility.building,
    facility.room, facility.capacity, trim(p_purpose), p_headcount, held,
    case when cardinality(p_starts_at) > 1 then 'weekly' else 'none' end,
    case when payment = 'quoted' then greatest(0, p_payment_amount_centavos) else 0 end,
    payment
  ) returning * into result;
  for i in 1..cardinality(p_starts_at) loop
    if p_starts_at[i] >= p_ends_at[i] then
      raise exception using errcode = '22023', message = 'End time must be after start time';
    end if;
    if extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60 > facility.max_duration_minutes then
      raise exception using errcode = '22023', message = 'Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now() or
       (i = 1 and p_starts_at[i] > now() + make_interval(days => facility.advance_booking_days)) then
      raise exception using errcode = '22023', message = 'Reservation date is outside the booking window';
    end if;
    insert into public.reservation_occurrences(
      request_id, facility_id, starts_at, ends_at, buffer_minutes
    ) values (result.id, facility.id, p_starts_at[i], p_ends_at[i], facility.booking_buffer_minutes);
  end loop;
  for attachment in select value from jsonb_array_elements(coalesce(p_attachment_metadata, '[]'::jsonb)) loop
    if attachment->>'storage_path' not like auth.uid()::text || '/%' then
      raise exception using errcode = '42501', message = 'Invalid attachment path';
    end if;
    insert into public.reservation_attachments(request_id, owner_id, storage_path, file_name, mime_type, byte_size)
    values (result.id, auth.uid(), attachment->>'storage_path', attachment->>'file_name',
            attachment->>'mime_type', (attachment->>'byte_size')::integer);
  end loop;
  event_id := public.reservation_event(result.id, 'submitted a reservation request', null,
    jsonb_build_object('held_for_verification', held), null, false);
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, result.id, event_id, 'reservation_submitted', 'New reservation request',
         result.requester_name || ' requested ' || result.facility_name
  from public.profiles p
  where p.role in ('internal_admin','external_admin') and p.account_status = 'active' and not held;
  return result;
end;
$$;

create or replace function public.reservation_action(
  p_request_id uuid,
  p_action text,
  p_reason text default null,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  request_row public.reservation_requests%rowtype;
  actor public.profiles%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  is_admin boolean;
  event_id uuid;
  journal_id uuid;
  affected_ids uuid[];
  now_version integer;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'Sign in required'; end if;
  if exists(select 1 from public.reservation_action_journal where actor_id=auth.uid() and idempotency_key=p_idempotency_key) then
    select r.* into request_row from public.reservation_requests r where r.id=p_request_id;
    return jsonb_build_object('request', to_jsonb(request_row), 'duplicate', true);
  end if;
  select * into actor from public.profiles where id=auth.uid();
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null then raise exception using errcode='P0002', message='Reservation not found'; end if;
  is_admin := public.reservation_is_admin();
  if not is_admin and request_row.requester_id <> auth.uid() then
    raise exception using errcode='42501', message='Forbidden';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode='40001', message='This reservation changed. Refresh and try again';
  end if;
  if p_action in ('approve','approve_partial','approve_bump','decline','request_changes','offer_alternative','reopen','expire','check_in','complete','no_show') and not is_admin then
    raise exception using errcode='42501', message='Administrator access required';
  end if;
  if p_action in ('decline','request_changes','offer_alternative','approve_bump','reopen') and coalesce(trim(p_reason),'')='' then
    raise exception using errcode='22023', message='A reason is required';
  end if;

  affected_ids := array[p_request_id];
  if p_action='approve_bump' then
    select coalesce(array_agg(distinct other.request_id), '{}') into affected_ids
    from public.reservation_occurrences wanted
    join public.reservation_occurrences other
      on other.facility_id=wanted.facility_id and other.booking_state='booked'
     and other.blocked_window && wanted.blocked_window and other.request_id<>wanted.request_id
    where wanted.request_id=p_request_id;
    affected_ids := array_append(affected_ids, p_request_id);
  end if;

  insert into public.reservation_action_journal(
    actor_id,idempotency_key,action,request_ids,before_requests,before_occurrences
  ) select auth.uid(),p_idempotency_key,p_action,affected_ids,
    coalesce((select jsonb_agg(to_jsonb(r)) from public.reservation_requests r where r.id=any(affected_ids)),'[]'::jsonb),
    coalesce((select jsonb_agg(to_jsonb(o)) from public.reservation_occurrences o where o.request_id=any(affected_ids)),'[]'::jsonb)
  returning id into journal_id;

  if p_action in ('approve','approve_partial','approve_bump') then
    if request_row.status <> 'pending' then raise exception using errcode='22023', message='Only pending requests can be approved'; end if;
    if request_row.headcount > request_row.facility_capacity then raise exception using errcode='22023', message='Headcount exceeds facility capacity'; end if;
    if request_row.held_for_verification then raise exception using errcode='22023', message='This request is held for verification'; end if;
    if p_action='approve' and exists(
      select 1 from public.reservation_occurrences wanted
      join public.reservation_occurrences other on other.facility_id=wanted.facility_id
       and other.booking_state='booked' and other.blocked_window && wanted.blocked_window
       and other.request_id<>wanted.request_id where wanted.request_id=p_request_id
    ) then raise exception using errcode='23P01', message='The facility is already booked for one or more requested times'; end if;
    if p_action='approve_bump' then
      if exists(select 1 from public.reservation_occurrences where request_id=any(affected_ids) and request_id<>p_request_id and starts_at<=now()) then
        raise exception using errcode='22023', message='Bookings that have started cannot be bumped';
      end if;
      update public.reservation_occurrences set booking_state='bumped', exception_reason=p_reason
      where request_id=any(affected_ids) and request_id<>p_request_id and booking_state='booked';
      update public.reservation_requests set status='changes_requested', decision_reason=p_reason
      where id=any(affected_ids) and id<>p_request_id;
    end if;
    if p_action='approve_partial' then
      update public.reservation_occurrences wanted set booking_state = case when exists(
        select 1 from public.reservation_occurrences other where other.facility_id=wanted.facility_id
          and other.booking_state='booked' and other.blocked_window && wanted.blocked_window
          and other.request_id<>wanted.request_id
      ) then 'changes_requested' else 'booked' end,
      exception_reason = case when exists(
        select 1 from public.reservation_occurrences other where other.facility_id=wanted.facility_id
          and other.booking_state='booked' and other.blocked_window && wanted.blocked_window
          and other.request_id<>wanted.request_id
      ) then 'Choose another time for this occurrence.' else null end
      where wanted.request_id=p_request_id and wanted.booking_state in ('requested','changes_requested');
    else
      update public.reservation_occurrences set booking_state='booked', exception_reason=null
      where request_id=p_request_id and booking_state in ('requested','changes_requested');
    end if;
    update public.reservation_requests set status='approved', decision_reason=null,
      decided_by=auth.uid(), decided_by_name=actor.full_name, decided_at=now(),
      payment_status=case when payment_status='quoted' then 'authorized' else payment_status end
    where id=p_request_id;
  elsif p_action='decline' then
    update public.reservation_occurrences set booking_state='cancelled', exception_reason=p_reason where request_id=p_request_id;
    update public.reservation_requests set status='declined',decision_reason=p_reason,decided_by=auth.uid(),decided_by_name=actor.full_name,decided_at=now(),
      payment_status=case when payment_status in ('quoted','authorized') then 'voided' else payment_status end where id=p_request_id;
  elsif p_action='request_changes' then
    update public.reservation_occurrences set booking_state='changes_requested',exception_reason=p_reason where request_id=p_request_id and booking_state='requested';
    update public.reservation_requests set status='changes_requested',decision_reason=p_reason,decided_by=auth.uid(),decided_by_name=actor.full_name,decided_at=now() where id=p_request_id;
  elsif p_action='offer_alternative' then
    select * into occurrence_row from public.reservation_occurrences where id=(p_payload->>'occurrence_id')::uuid and request_id=p_request_id for update;
    if occurrence_row.id is null then raise exception using errcode='P0002', message='Occurrence not found'; end if;
    update public.reservation_occurrences set proposed_starts_at=(p_payload->>'starts_at')::timestamptz,
      proposed_ends_at=(p_payload->>'ends_at')::timestamptz,booking_state='changes_requested',exception_reason=p_reason where id=occurrence_row.id;
    update public.reservation_requests set status='changes_requested',decision_reason=p_reason,decided_by=auth.uid(),decided_by_name=actor.full_name,decided_at=now() where id=p_request_id;
  elsif p_action='accept_alternative' then
    if request_row.requester_id<>auth.uid() then raise exception using errcode='42501', message='Only the requester can accept an alternative'; end if;
    select * into occurrence_row from public.reservation_occurrences where id=(p_payload->>'occurrence_id')::uuid and request_id=p_request_id for update;
    if occurrence_row.proposed_starts_at is null then raise exception using errcode='22023', message='No alternative is awaiting acceptance'; end if;
    update public.reservation_occurrences set starts_at=proposed_starts_at,ends_at=proposed_ends_at,
      proposed_starts_at=null,proposed_ends_at=null,booking_state='booked',exception_reason=null where id=occurrence_row.id;
    update public.reservation_requests set status='approved',decision_reason=null,decided_at=now(),
      payment_status=case when payment_status='quoted' then 'authorized' else payment_status end where id=p_request_id;
  elsif p_action='cancel' then
    if request_row.requester_id<>auth.uid() and not is_admin then raise exception using errcode='42501', message='Forbidden'; end if;
    if p_payload ? 'occurrence_id' then
      update public.reservation_occurrences set booking_state='cancelled',exception_reason=coalesce(nullif(trim(p_reason),''),'Cancelled by requester')
      where id=(p_payload->>'occurrence_id')::uuid and request_id=p_request_id and starts_at>now() and lifecycle_stage='booked';
    else
      update public.reservation_occurrences set booking_state='cancelled',exception_reason=coalesce(nullif(trim(p_reason),''),'Cancelled by requester')
      where request_id=p_request_id and starts_at>now() and lifecycle_stage='booked';
    end if;
    if not exists(select 1 from public.reservation_occurrences where request_id=p_request_id and booking_state in ('requested','booked','changes_requested')) then
      update public.reservation_requests set status='cancelled',decision_reason=coalesce(nullif(trim(p_reason),''),'Cancelled by requester'),
        payment_status=case when payment_status in ('quoted','authorized') then 'voided' else payment_status end where id=p_request_id;
    end if;
  elsif p_action='resubmit' then
    if request_row.requester_id<>auth.uid() or request_row.status<>'changes_requested' then raise exception using errcode='42501', message='This request cannot be resubmitted'; end if;
    update public.reservation_requests set status='pending',decision_reason=null,decided_by=null,decided_by_name=null,decided_at=null,
      purpose=coalesce(nullif(trim(p_payload->>'purpose'),''),purpose),
      headcount=coalesce((p_payload->>'headcount')::integer,headcount) where id=p_request_id;
    update public.reservation_occurrences set booking_state='requested',exception_reason=null,proposed_starts_at=null,proposed_ends_at=null
      where request_id=p_request_id and booking_state in ('changes_requested','bumped');
  elsif p_action='reopen' then
    if exists(select 1 from public.reservation_occurrences where request_id=p_request_id and lifecycle_stage in ('completed','no_show')) then
      raise exception using errcode='22023', message='Completed or no-show bookings cannot be reopened';
    end if;
    update public.reservation_occurrences set booking_state='requested',lifecycle_stage='booked',exception_reason=null where request_id=p_request_id and starts_at>now();
    update public.reservation_requests set status='pending',decision_reason=p_reason,decided_by=null,decided_by_name=null,decided_at=null,
      payment_status=case when payment_status='authorized' then 'quoted' else payment_status end where id=p_request_id;
  elsif p_action='expire' then
    if request_row.status<>'pending' or exists(select 1 from public.reservation_occurrences where request_id=p_request_id and starts_at>now()) then
      raise exception using errcode='22023', message='Only stale pending requests can expire';
    end if;
    update public.reservation_occurrences set booking_state='expired' where request_id=p_request_id;
    update public.reservation_requests set status='expired',decided_by=auth.uid(),decided_by_name=actor.full_name,decided_at=now(),payment_status=case when payment_status='quoted' then 'voided' else payment_status end where id=p_request_id;
  elsif p_action in ('check_in','complete','no_show') then
    select * into occurrence_row from public.reservation_occurrences where id=(p_payload->>'occurrence_id')::uuid and request_id=p_request_id for update;
    if occurrence_row.id is null or occurrence_row.booking_state<>'booked' then raise exception using errcode='22023', message='This occurrence is not booked'; end if;
    if p_action='check_in' and now() < occurrence_row.starts_at - interval '30 minutes' then raise exception using errcode='22023', message='Check-in opens 30 minutes before the booking'; end if;
    if p_action='complete' and occurrence_row.lifecycle_stage<>'checked_in' then raise exception using errcode='22023', message='Check in before completing this booking'; end if;
    if p_action='no_show' and now() < occurrence_row.starts_at + interval '15 minutes' then raise exception using errcode='22023', message='The no-show grace period has not ended'; end if;
    update public.reservation_occurrences set lifecycle_stage=case p_action when 'check_in' then 'checked_in' when 'complete' then 'completed' else 'no_show' end where id=occurrence_row.id;
    if p_action='check_in' then update public.reservation_requests set payment_status=case when payment_status='authorized' then 'captured' else payment_status end where id=p_request_id; end if;
  else
    raise exception using errcode='22023', message='Unknown reservation action';
  end if;

  select version into now_version from public.reservation_requests where id=p_request_id;
  update public.reservation_action_journal set after_versions=jsonb_build_object(p_request_id::text,now_version) where id=journal_id;
  event_id := public.reservation_event(p_request_id, replace(p_action,'_',' '), p_reason, p_payload,
    case when p_payload ? 'occurrence_id' then (p_payload->>'occurrence_id')::uuid else null end,
    p_action not in ('check_in'));
  perform public.notify_reservation_user(p_request_id,event_id,'reservation_'||p_action,
    initcap(replace(p_action,'_',' ')),coalesce(nullif(trim(p_reason),''),'Your reservation was updated.'));
  select * into request_row from public.reservation_requests where id=p_request_id;
  return jsonb_build_object('request',to_jsonb(request_row),'action_id',journal_id,'undo_until',now()+interval '8 seconds');
exception when exclusion_violation then
  raise exception using errcode='23P01', message='The facility was booked by another request. Refresh and try again';
end;
$$;

create or replace function public.bulk_approve_reservations(
  p_request_ids uuid[], p_expected_versions jsonb, p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare id uuid; result jsonb; action_ids uuid[] := array[]::uuid[];
begin
  if not public.reservation_is_admin() then raise exception using errcode='42501', message='Administrator access required'; end if;
  foreach id in array p_request_ids loop
    result := public.reservation_action(id,'approve',null,'{}'::jsonb,
      (p_expected_versions->>id::text)::integer,
      (md5(p_idempotency_key::text || id::text)::uuid));
    action_ids := array_append(action_ids,(result->>'action_id')::uuid);
  end loop;
  return jsonb_build_object('action_ids',action_ids);
end;
$$;

create or replace function public.undo_reservation_action(p_action_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare journal public.reservation_action_journal%rowtype; item jsonb; snapshot public.reservation_requests%rowtype; occurrence public.reservation_occurrences%rowtype;
begin
  select * into journal from public.reservation_action_journal where id=p_action_id for update;
  if journal.id is null or journal.actor_id<>auth.uid() then raise exception using errcode='42501', message='Undo is not available'; end if;
  if journal.undone_at is not null or now()>journal.undo_until then raise exception using errcode='22023', message='The undo window has ended'; end if;
  for item in select value from jsonb_array_elements(journal.before_requests) loop
    snapshot := jsonb_populate_record(null::public.reservation_requests,item);
    update public.reservation_requests set status=snapshot.status,held_for_verification=snapshot.held_for_verification,
      decision_reason=snapshot.decision_reason,decided_by=snapshot.decided_by,decided_by_name=snapshot.decided_by_name,
      decided_at=snapshot.decided_at,payment_status=snapshot.payment_status where id=snapshot.id;
  end loop;
  delete from public.reservation_occurrences where request_id=any(journal.request_ids);
  for item in select value from jsonb_array_elements(journal.before_occurrences) loop
    occurrence := jsonb_populate_record(null::public.reservation_occurrences,item);
    insert into public.reservation_occurrences(id,request_id,facility_id,starts_at,ends_at,buffer_minutes,booking_state,lifecycle_stage,
      proposed_starts_at,proposed_ends_at,exception_reason,created_at,updated_at)
    values(occurrence.id,occurrence.request_id,occurrence.facility_id,occurrence.starts_at,occurrence.ends_at,occurrence.buffer_minutes,
      occurrence.booking_state,occurrence.lifecycle_stage,occurrence.proposed_starts_at,occurrence.proposed_ends_at,occurrence.exception_reason,
      occurrence.created_at,now());
  end loop;
  update public.reservation_action_journal set undone_at=now() where id=journal.id;
  perform public.reservation_event(journal.request_ids[1],'undid '||replace(journal.action,'_',' '),null,jsonb_build_object('action_id',journal.id));
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.release_verified_reservations()
returns trigger language plpgsql security definer set search_path=public as $$
declare row public.reservation_requests%rowtype; event_id uuid;
begin
  if new.verification_status='verified' and old.verification_status is distinct from 'verified' then
    for row in select * from public.reservation_requests where requester_id=new.id and held_for_verification for update loop
      if exists(select 1 from public.reservation_occurrences where request_id=row.id and starts_at>now()) then
        update public.reservation_requests set held_for_verification=false where id=row.id;
        event_id := public.reservation_event(row.id,'released after campus verification',null,'{}'::jsonb,null,false);
        insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
        select p.id,row.id,event_id,'reservation_released','Reservation released',row.requester_name||'''s request is ready for review.'
        from public.profiles p where p.role in ('internal_admin','external_admin') and p.account_status='active';
      else
        update public.reservation_requests set held_for_verification=false,status='expired',payment_status=case when payment_status='quoted' then 'voided' else payment_status end where id=row.id;
        update public.reservation_occurrences set booking_state='expired' where request_id=row.id;
      end if;
    end loop;
  end if;
  return new;
end;
$$;

create or replace function public.generate_my_reservation_reminders()
returns void language sql security definer set search_path=public as $$
  insert into public.app_notifications(recipient_id,request_id,kind,title,body)
  select r.requester_id,r.id,'reservation_reminder','Reservation tomorrow',
         r.facility_name || ' · ' || to_char(min(o.starts_at) at time zone 'Asia/Manila','HH24:MI')
  from public.reservation_requests r
  join public.reservation_occurrences o on o.request_id=r.id
  where r.requester_id=auth.uid() and o.booking_state='booked'
    and (o.starts_at at time zone 'Asia/Manila')::date =
        (now() at time zone 'Asia/Manila')::date + 1
    and coalesce((select day_before_reminders from public.notification_preferences where user_id=auth.uid()),true)
  group by r.id
  on conflict (recipient_id,request_id,kind) where kind='reservation_reminder' do nothing;
$$;

drop trigger if exists profiles_release_verified_reservations on public.profiles;
create trigger profiles_release_verified_reservations after update of verification_status on public.profiles
for each row execute procedure public.release_verified_reservations();

create or replace function public.protect_future_reservations_on_facility_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare request_row public.reservation_requests%rowtype; event_id uuid;
begin
  if new.archived_at is not null and old.archived_at is null and exists(
    select 1 from public.reservation_occurrences
    where facility_id=new.id and booking_state='booked' and starts_at>now()
  ) then
    raise exception using errcode='23503', message='Move or cancel future bookings before archiving this facility';
  end if;
  if new.status='maintenance' and old.status is distinct from 'maintenance' then
    for request_row in
      select distinct r.* from public.reservation_requests r
      join public.reservation_occurrences o on o.request_id=r.id
      where o.facility_id=new.id and o.booking_state='booked' and o.starts_at>now()
    loop
      event_id := public.reservation_event(request_row.id,'flagged by facility maintenance',
        'The facility entered maintenance. An administrator must relocate or cancel this booking.');
      perform public.notify_reservation_user(request_row.id,event_id,'facility_maintenance',
        'Facility maintenance affects your booking',
        'An administrator will offer another time or facility.');
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists facilities_protect_reservations on public.facilities;
create trigger facilities_protect_reservations before update of archived_at,status on public.facilities
for each row execute procedure public.protect_future_reservations_on_facility_change();

alter table public.reservation_requests enable row level security;
alter table public.reservation_occurrences enable row level security;
alter table public.reservation_attachments enable row level security;
alter table public.reservation_events enable row level security;
alter table public.app_notifications enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.reservation_action_journal enable row level security;

grant select on public.reservation_requests,public.reservation_occurrences,public.reservation_attachments,public.reservation_events to authenticated;
grant select,update on public.app_notifications,public.notification_preferences to authenticated;
grant insert on public.notification_preferences to authenticated;
grant execute on function public.submit_reservation(uuid,uuid,text,integer,timestamptz[],timestamptz[],jsonb,integer) to authenticated;
grant execute on function public.reservation_action(uuid,text,text,jsonb,integer,uuid) to authenticated;
grant execute on function public.bulk_approve_reservations(uuid[],jsonb,uuid) to authenticated;
grant execute on function public.undo_reservation_action(uuid) to authenticated;
grant execute on function public.generate_my_reservation_reminders() to authenticated;

create policy reservation_requests_read on public.reservation_requests for select to authenticated
using (requester_id=auth.uid() or public.reservation_is_admin());
create policy reservation_occurrences_read on public.reservation_occurrences for select to authenticated
using (exists(select 1 from public.reservation_requests r where r.id=request_id and (r.requester_id=auth.uid() or public.reservation_is_admin())));
create policy reservation_attachments_read on public.reservation_attachments for select to authenticated
using (owner_id=auth.uid() or public.reservation_is_admin());
create policy reservation_events_read on public.reservation_events for select to authenticated
using (exists(select 1 from public.reservation_requests r where r.id=request_id and (r.requester_id=auth.uid() or public.reservation_is_admin())));
create policy app_notifications_read on public.app_notifications for select to authenticated using (recipient_id=auth.uid());
create policy app_notifications_update on public.app_notifications for update to authenticated using (recipient_id=auth.uid()) with check (recipient_id=auth.uid());
create policy notification_preferences_own on public.notification_preferences for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy reservation_journal_own on public.reservation_action_journal for select to authenticated using(actor_id=auth.uid());

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('reservation-attachments','reservation-attachments',false,10485760,array['image/jpeg','image/png','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;

create policy reservation_files_insert_own on storage.objects for insert to authenticated
with check(bucket_id='reservation-attachments' and (storage.foldername(name))[1]=auth.uid()::text);
create policy reservation_files_read on storage.objects for select to authenticated
using(bucket_id='reservation-attachments' and ((storage.foldername(name))[1]=auth.uid()::text or public.reservation_is_admin()));
create policy reservation_files_delete_own on storage.objects for delete to authenticated
using(bucket_id='reservation-attachments' and ((storage.foldername(name))[1]=auth.uid()::text or public.reservation_is_admin()));

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reservation_requests') then alter publication supabase_realtime add table public.reservation_requests; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reservation_occurrences') then alter publication supabase_realtime add table public.reservation_occurrences; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='app_notifications') then alter publication supabase_realtime add table public.app_notifications; end if;
end $$;
