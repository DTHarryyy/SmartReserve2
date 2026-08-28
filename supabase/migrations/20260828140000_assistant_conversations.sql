-- User-facing assistant history. This is intentionally separate from the
-- reservation event/audit trail, which remains the authoritative record.
create table if not exists public.assistant_conversations (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  title text not null default 'New chat' check (char_length(trim(title)) between 1 and 120),
  active_draft jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now()
);

create index if not exists assistant_conversations_owner_activity_idx
  on public.assistant_conversations(owner_id, last_activity_at desc, id desc);

create table if not exists public.assistant_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.assistant_conversations(id) on delete cascade,
  sender text not null check (sender in ('user', 'assistant', 'system')),
  message_type text not null check (message_type in ('text', 'chips', 'facilities', 'confirm', 'reservations', 'activity')),
  text text not null default '',
  payload jsonb not null default '{}'::jsonb,
  reservation_id uuid references public.reservation_requests(id) on delete set null,
  action text,
  created_at timestamptz not null default now()
);

create index if not exists assistant_messages_conversation_created_idx
  on public.assistant_messages(conversation_id, created_at asc, id asc);

create or replace function public.touch_assistant_conversation()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists assistant_conversations_touch on public.assistant_conversations;
create trigger assistant_conversations_touch
before update on public.assistant_conversations
for each row execute procedure public.touch_assistant_conversation();

-- A transcript may only link a reservation owned by the person writing it.
-- This prevents it from becoming a way to discover another account's booking.
create or replace function public.validate_assistant_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  conversation_owner uuid;
begin
  select owner_id into conversation_owner
  from public.assistant_conversations where id = new.conversation_id;
  if conversation_owner is null or conversation_owner <> auth.uid() then
    raise exception using errcode = '42501', message = 'Conversation access denied';
  end if;
  if new.reservation_id is not null and not exists (
    select 1 from public.reservation_requests
    where id = new.reservation_id and requester_id = auth.uid()
  ) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  return new;
end;
$$;

drop trigger if exists assistant_messages_validate on public.assistant_messages;
create trigger assistant_messages_validate
before insert or update on public.assistant_messages
for each row execute procedure public.validate_assistant_message();

create or replace function public.bump_assistant_conversation_activity()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.assistant_conversations
  set last_activity_at = new.created_at
  where id = new.conversation_id;
  return new;
end;
$$;

drop trigger if exists assistant_messages_bump_conversation on public.assistant_messages;
create trigger assistant_messages_bump_conversation
after insert on public.assistant_messages
for each row execute procedure public.bump_assistant_conversation_activity();

alter table public.assistant_conversations enable row level security;
alter table public.assistant_messages enable row level security;

revoke all on public.assistant_conversations, public.assistant_messages from public, anon;
grant select, insert, update, delete on public.assistant_conversations to authenticated;
grant select, insert, update, delete on public.assistant_messages to authenticated;

create policy assistant_conversations_owner
on public.assistant_conversations for all to authenticated
using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy assistant_messages_owner
on public.assistant_messages for all to authenticated
using (exists (
  select 1 from public.assistant_conversations c
  where c.id = conversation_id and c.owner_id = auth.uid()
)) with check (exists (
  select 1 from public.assistant_conversations c
  where c.id = conversation_id and c.owner_id = auth.uid()
));
