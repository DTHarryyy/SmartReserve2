-- context_summary is NOT NULL DEFAULT ''. The first version of this writer
-- used nullif(..., '') and would have raised 23502 on a blank summary --
-- which the edge function currently cannot send, because extractChannels drops
-- empty ones, but that is a caller's discipline protecting a database
-- constraint, and the constraint should not depend on it.
create or replace function public.assistant_update_conversation_summary(
  p_owner_id uuid,
  p_conversation_id uuid,
  p_summary text,
  p_turn_count integer default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  updated integer;
  clean_summary text := left(btrim(coalesce(p_summary, '')), 1000);
begin
  if p_owner_id is null or p_conversation_id is null then
    return false;
  end if;

  update public.assistant_conversations
  set
    context_summary = clean_summary,
    turn_count = greatest(coalesce(p_turn_count, turn_count, 0), 0),
    summary_through_message_id = (
      select m.id from public.assistant_messages m
      where m.conversation_id = p_conversation_id
      order by m.created_at desc, m.id desc
      limit 1
    )
  where id = p_conversation_id
    and owner_id = p_owner_id;

  get diagnostics updated = row_count;
  return updated > 0;
end;
$$;

revoke execute on function public.assistant_update_conversation_summary(uuid, uuid, text, integer)
  from public, anon, authenticated;
grant execute on function public.assistant_update_conversation_summary(uuid, uuid, text, integer)
  to service_role;

notify pgrst, 'reload schema';
