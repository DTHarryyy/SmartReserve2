-- The knowledge base is the only place the assistant is allowed to get policy
-- wording from, so two things have to hold: an external renter must never be
-- shown internal-only guidance (or vice versa), and retrieval must actually
-- find the chunk for the way people really ask -- including in Taglish.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(12);

create temp table assistant_kb_actors as
select
  (
    select p.id from public.profiles p
    where public.requester_admin_lane(p.id) = 'internal'
    order by p.created_at
    limit 1
  ) as internal_user,
  (
    select p.id from public.profiles p
    where public.requester_admin_lane(p.id) = 'external'
    order by p.created_at
    limit 1
  ) as external_user;

select ok(to_regclass('public.assistant_knowledge_base') is not null,
  'the knowledge base table exists');
select has_function('public', 'assistant_knowledge_search', array['text', 'integer'],
  'assistant_knowledge_search exists');

-- Answers are capped by constraint, not by convention: a long answer is a
-- token cost paid on every retrieval that includes it.
select ok(
  (select count(*) from public.assistant_knowledge_base
   where char_length(answer) > 600) = 0,
  'no seeded answer exceeds the 600 character budget'
);
select ok(
  (select count(*) from public.assistant_knowledge_base) >= 20,
  'the seed covers the documented topics'
);
select ok(
  (select count(distinct topic) from public.assistant_knowledge_base) >= 6,
  'every policy topic is represented'
);

select throws_ok(
  $$insert into public.assistant_knowledge_base(slug, topic, question, answer)
    values ('bad.too_long', 'payment', 'Is this too long?', repeat('x', 601))$$,
  '23514',
  null,
  'an over-long answer is rejected by the schema'
);

select throws_ok(
  $$insert into public.assistant_knowledge_base(slug, topic, audience, question, answer)
    values ('bad.audience', 'payment', array['everyone'], 'Who?', 'Nobody.')$$,
  '23514',
  null,
  'an unknown audience is rejected'
);

-- ---------------------------------------------------------------------------
-- anon has no business reading policy chunks; a chatbot turn always has a
-- session behind it.
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.assistant_knowledge_search(text, integer)', 'execute'),
  'anon cannot search the knowledge base'
);

-- ---------------------------------------------------------------------------
-- Retrieval quality and audience isolation
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claim.sub',
  (select internal_user::text from assistant_kb_actors), true);

select ok(
  jsonb_array_length(
    public.assistant_knowledge_search('magkano bayad down payment', 3) -> 'chunks'
  ) > 0,
  'a Taglish payment question finds an answer'
);

select ok(
  jsonb_array_length(
    public.assistant_knowledge_search('bakit wala pa permiso ko', 3) -> 'chunks'
  ) > 0,
  'a Taglish permit question finds an answer'
);

-- The strict one. An internal requester asking about external rules must get
-- internal guidance, never the external-only chunk.
select is(
  (
    select count(*)
    from jsonb_array_elements(
      public.assistant_knowledge_search('rules for external renters', 5) -> 'chunks'
    ) chunk
    where chunk ->> 'slug' in (
      select slug from public.assistant_knowledge_base
      where not (audience && array['internal'])
    )
  ),
  0::bigint,
  'an internal requester never receives external-only guidance'
);

select set_config('request.jwt.claim.sub',
  (select coalesce(external_user, internal_user)::text from assistant_kb_actors), true);

select is(
  (
    select count(*)
    from jsonb_array_elements(
      public.assistant_knowledge_search('campus organization rules', 5) -> 'chunks'
    ) chunk
    where chunk ->> 'slug' in (
      select slug from public.assistant_knowledge_base
      where not (audience && array[public.requester_admin_lane()])
    )
  ),
  0::bigint,
  'a requester never receives guidance addressed to the other lane'
);

select * from finish();
rollback;
