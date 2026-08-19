alter table public.profiles
  add column if not exists suspension_reason text,
  add column if not exists suspended_until date,
  add column if not exists invitation_sent_at timestamptz;

create table if not exists public.account_admin_events (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  target_id uuid references public.profiles(id) on delete set null,
  target_email text not null,
  action text not null,
  reason text,
  before_values jsonb not null default '{}'::jsonb,
  after_values jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.account_admin_events enable row level security;
grant select on public.account_admin_events to authenticated;

drop policy if exists account_admin_events_select_internal_admin
on public.account_admin_events;
create policy account_admin_events_select_internal_admin
on public.account_admin_events
for select to authenticated
using (public.is_internal_admin());

create or replace function public.normalize_expired_suspensions()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.profiles%rowtype;
  updated public.profiles%rowtype;
begin
  for target in
    select * from public.profiles
    where account_status = 'suspended'
      and suspended_until is not null
      and suspended_until <= (now() at time zone 'Asia/Manila')::date
    order by id
    for update
  loop
    update public.profiles
    set account_status = 'active',
        suspension_reason = null,
        suspended_until = null
    where id = target.id
    returning * into updated;

    insert into public.account_admin_events (
      actor_id, target_id, target_email, action, reason,
      before_values, after_values
    ) values (
      null, target.id, target.email, 'automatic_lift_suspension',
      'Scheduled suspension end date reached.',
      to_jsonb(target), to_jsonb(updated)
    );
  end loop;
end;
$$;

revoke all on function public.normalize_expired_suspensions() from public, anon, authenticated;
grant execute on function public.normalize_expired_suspensions() to service_role;

create or replace function public.normalize_my_expired_suspension()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.profiles%rowtype;
  updated public.profiles%rowtype;
begin
  if auth.uid() is null then
    return false;
  end if;

  select * into target
  from public.profiles
  where id = auth.uid()
    and account_status = 'suspended'
    and suspended_until is not null
    and suspended_until <= (now() at time zone 'Asia/Manila')::date
  for update;

  if not found then
    return false;
  end if;

  update public.profiles
  set account_status = 'active',
      suspension_reason = null,
      suspended_until = null
  where id = target.id
  returning * into updated;

  insert into public.account_admin_events (
    actor_id, target_id, target_email, action, reason,
    before_values, after_values
  ) values (
    null, target.id, target.email, 'automatic_lift_suspension',
    'Scheduled suspension end date reached.',
    to_jsonb(target), to_jsonb(updated)
  );
  return true;
end;
$$;

revoke all on function public.normalize_my_expired_suspension()
from public, anon, authenticated;
grant execute on function public.normalize_my_expired_suspension()
to authenticated;

create or replace function public.activate_accepted_admin_invite()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    update public.profiles
    set account_status = 'active'
    where id = new.id
      and account_status = 'invited'
      and role in ('internal_admin', 'external_admin');
  end if;
  return new;
end;
$$;

drop trigger if exists accepted_admin_invite_profile_sync on auth.users;
create trigger accepted_admin_invite_profile_sync
after update of email_confirmed_at on auth.users
for each row execute procedure public.activate_accepted_admin_invite();

create or replace function public.admin_manage_account(
  p_actor uuid,
  p_target uuid,
  p_action text,
  p_role text default null,
  p_reason text default null,
  p_suspended_until date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.profiles%rowtype;
  updated public.profiles%rowtype;
  before_values jsonb;
  after_values jsonb;
  active_internal_admins integer;
  event_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform public.normalize_expired_suspensions();

  if not public.is_internal_admin(p_actor) then
    raise exception using errcode = '42501', message = 'Forbidden';
  end if;

  perform id
  from public.profiles
  where role = 'internal_admin'
  order by id
  for update;

  select * into target
  from public.profiles
  where id = p_target
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;

  before_values := to_jsonb(target);
  select count(*) into active_internal_admins
  from public.profiles
  where role = 'internal_admin' and account_status = 'active';

  case p_action
    when 'change_role' then
      if p_target = p_actor then
        raise exception using errcode = 'P0001', message = 'You cannot change your own role';
      end if;
      if p_role is null or p_role not in (
        'student', 'faculty', 'staff', 'guest', 'internal_admin', 'external_admin'
      ) then
        raise exception using errcode = '22023', message = 'Invalid role';
      end if;
      if event_reason is null then
        raise exception using errcode = '22023', message = 'A reason is required';
      end if;
      if target.role = 'internal_admin'
          and target.account_status = 'active'
          and p_role <> 'internal_admin'
          and active_internal_admins <= 1 then
        raise exception using errcode = 'P0001', message = 'The last active internal admin cannot be demoted';
      end if;
      update public.profiles set role = p_role where id = p_target;

    when 'suspend' then
      if p_target = p_actor then
        raise exception using errcode = 'P0001', message = 'You cannot suspend your own account';
      end if;
      if event_reason is null then
        raise exception using errcode = '22023', message = 'A reason is required';
      end if;
      if p_suspended_until is not null
          and p_suspended_until <= (now() at time zone 'Asia/Manila')::date then
        raise exception using errcode = '22023', message = 'Choose a future lift date';
      end if;
      if target.role = 'internal_admin'
          and target.account_status = 'active'
          and active_internal_admins <= 1 then
        raise exception using errcode = 'P0001', message = 'The last active internal admin cannot be suspended';
      end if;
      update public.profiles
      set account_status = 'suspended',
          suspension_reason = event_reason,
          suspended_until = p_suspended_until
      where id = p_target;

    when 'lift_suspension' then
      update public.profiles
      set account_status = 'active',
          suspension_reason = null,
          suspended_until = null
      where id = p_target;

    when 'request_reverification' then
      if target.role in ('internal_admin', 'external_admin') then
        raise exception using errcode = '22023', message = 'Administrator accounts are not campus-verified';
      end if;
      if not exists (
        select 1 from public.verification_submissions where user_id = p_target
      ) then
        raise exception using errcode = 'P0002', message = 'No verification submission exists for this account';
      end if;
      event_reason := coalesce(
        event_reason,
        'An administrator requested re-verification. Submit a current document.'
      );
      update public.verification_submissions
      set status = 'changes_requested',
          reason = event_reason,
          decided_at = now(),
          decided_by = p_actor
      where user_id = p_target;
      update public.profiles
      set verification_status = 'pending'
      where id = p_target;

    else
      raise exception using errcode = '22023', message = 'Invalid account action';
  end case;

  select * into updated from public.profiles where id = p_target;
  after_values := to_jsonb(updated);

  insert into public.account_admin_events (
    actor_id, target_id, target_email, action, reason, before_values, after_values
  ) values (
    p_actor, p_target, target.email, p_action, event_reason,
    before_values, after_values
  );

  return after_values;
end;
$$;

revoke all on function public.admin_manage_account(uuid, uuid, text, text, text, date)
from public, anon, authenticated;
grant execute on function public.admin_manage_account(uuid, uuid, text, text, text, date)
to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'profiles'
  ) then
    alter publication supabase_realtime add table public.profiles;
  end if;
end;
$$;
