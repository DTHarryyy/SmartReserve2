-- Persist the conversation's rolling summary.
--
-- assistant_conversations.context_summary, summary_through_message_id and
-- turn_count were added with the AI foundation and nothing ever wrote them:
-- the client had a field for the summary, the edge function read one, the
-- prompt injected one, and no code anywhere produced one. This is the missing
-- producer.
--
-- Ownership is re-checked here rather than trusted. The conversation id
-- reaches the edge function in the request body, which makes it the caller's
-- claim; the user id comes from the verified JWT. Matching on both means a
-- forged id writes nothing instead of writing into someone else's chat. The
-- function is service-role only because the caller-scoped client would be
-- blocked by RLS on a conversation that is not theirs -- which is the correct
-- outcome, but silently, and this way the mismatch is visible as a 0.
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
begin
  if p_owner_id is null or p_conversation_id is null then
    return false;
  end if;

  update public.assistant_conversations
  set
    context_summary = nullif(left(btrim(coalesce(p_summary, '')), 1000), ''),
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
