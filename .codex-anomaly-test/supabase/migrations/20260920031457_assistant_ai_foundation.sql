-- Room in the transcript for model-assisted turns.
--
-- assistant_messages.message_type is a CHECK constraint, not an enum, so a new
-- kind needs a migration -- the existing vocabulary would reject every message
-- the AI layer writes.
--
-- 'ai_text'  an answer the cloud model phrased. Stored distinctly from 'text'
--            so a transcript can be audited for what the model actually said,
--            and so the UI can mark it.
-- 'proposal' a booking or cancellation the model suggested. It is a record of
--            an offer, never of an action: nothing is written until the user
--            taps the confirm card.

alter table public.assistant_messages
  drop constraint if exists assistant_messages_message_type_check;

alter table public.assistant_messages
  add constraint assistant_messages_message_type_check
  check (message_type in (
    'text', 'chips', 'facilities', 'confirm', 'reservations', 'activity',
    'ai_text', 'proposal'
  ));

-- Older turns collapse into a summary rather than being replayed in full.
-- Regenerated every few turns, so summarisation cost is amortised instead of
-- being paid on every message.
alter table public.assistant_conversations
  add column if not exists context_summary text not null default '',
  add column if not exists summary_through_message_id uuid,
  add column if not exists turn_count integer not null default 0
    check (turn_count >= 0);

alter table public.assistant_conversations
  drop constraint if exists assistant_conversations_summary_length;
alter table public.assistant_conversations
  add constraint assistant_conversations_summary_length
  check (char_length(context_summary) <= 1000);

notify pgrst, 'reload schema';
