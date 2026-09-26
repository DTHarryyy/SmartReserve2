begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(7);

create temp table assistant_chat_actors as
select
  (select id from public.profiles where role = 'user' order by created_at limit 1) as user_id,
  (select id from public.profiles where role = 'internal_admin' order by created_at limit 1) as other_id;

select ok(to_regclass('public.assistant_conversations') is not null,
  'assistant conversations table exists');
select ok(to_regclass('public.assistant_messages') is not null,
  'assistant messages table exists');

set local role authenticated;
select set_config('request.jwt.claim.sub',
  (select user_id::text from assistant_chat_actors), true);

insert into public.assistant_conversations(id, owner_id, title)
select 'a1000000-0000-0000-0000-000000000001', user_id, 'Chat history test'
from assistant_chat_actors;

insert into public.assistant_messages(
  conversation_id, sender, message_type, text, created_at
) values
  ('a1000000-0000-0000-0000-000000000001', 'user', 'text', 'First', now()),
  ('a1000000-0000-0000-0000-000000000001', 'assistant', 'text', 'Second', now() + interval '1 second');

select is((select count(*) from public.assistant_messages
  where conversation_id = 'a1000000-0000-0000-0000-000000000001'), 2::bigint,
  'an owner can append ordered transcript messages');
select is((select text from public.assistant_messages
  where conversation_id = 'a1000000-0000-0000-0000-000000000001'
  order by created_at desc limit 1), 'Second', 'messages retain chronological order');

select set_config('request.jwt.claim.sub',
  (select other_id::text from assistant_chat_actors), true);
select is((select count(*) from public.assistant_conversations
  where id = 'a1000000-0000-0000-0000-000000000001'), 0::bigint,
  'a different account cannot read a conversation');
select throws_ok(
  $$insert into public.assistant_messages(conversation_id, sender, message_type, text)
    values ('a1000000-0000-0000-0000-000000000001', 'user', 'text', 'Not mine')$$,
  '42501', 'Conversation access denied',
  'a different account cannot append to a conversation'
);

select set_config('request.jwt.claim.sub',
  (select user_id::text from assistant_chat_actors), true);
delete from public.assistant_conversations
where id = 'a1000000-0000-0000-0000-000000000001';
select is((select count(*) from public.assistant_messages
  where conversation_id = 'a1000000-0000-0000-0000-000000000001'), 0::bigint,
  'deleting a conversation cascades to its messages');

select * from finish();
rollback;
