-- Harden assistant history helpers after the initial table rollout.
create or replace function public.touch_assistant_conversation()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create index if not exists assistant_messages_reservation_idx
  on public.assistant_messages(reservation_id)
  where reservation_id is not null;

revoke execute on function public.touch_assistant_conversation() from public, anon, authenticated;
revoke execute on function public.validate_assistant_message() from public, anon, authenticated;
revoke execute on function public.bump_assistant_conversation_activity() from public, anon, authenticated;

drop policy if exists assistant_conversations_owner on public.assistant_conversations;
create policy assistant_conversations_owner
on public.assistant_conversations for all to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

drop policy if exists assistant_messages_owner on public.assistant_messages;
create policy assistant_messages_owner
on public.assistant_messages for all to authenticated
using (exists (
  select 1 from public.assistant_conversations c
  where c.id = conversation_id and c.owner_id = (select auth.uid())
)) with check (exists (
  select 1 from public.assistant_conversations c
  where c.id = conversation_id and c.owner_id = (select auth.uid())
));
