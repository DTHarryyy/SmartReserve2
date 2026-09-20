-- The assistant's policy answers.
--
-- Two reasons this is a table rather than prose in a prompt. First, cost: a
-- system prompt carrying every policy would be paid for on every single
-- request, whereas retrieval sends at most three short chunks and only when
-- the question is policy-shaped. Second, correctness: policy here is the same
-- text the app already shows -- permit blockers, booking block reasons, role
-- privileges -- so the assistant cannot drift from what the screens say.
--
-- Answers are capped at 600 characters by constraint. That is a token budget
-- expressed as a schema rule, not a style preference.

create table if not exists public.assistant_knowledge_base (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique
    check (slug ~ '^[a-z][a-z0-9_.]{2,80}$'),
  topic text not null check (topic in (
    'reservation', 'payment', 'permit', 'cancellation',
    'facility', 'equipment', 'account'
  )),
  -- Which requester lanes may see the chunk. External renters must not be
  -- shown internal-only guidance, and neither should see admin runbooks.
  audience text[] not null default array['internal', 'external']
    check (
      audience <> '{}'
      and audience <@ array['internal', 'external', 'admin']
    ),
  question text not null check (char_length(trim(question)) between 5 and 200),
  answer text not null check (char_length(trim(answer)) between 5 and 600),
  -- Taglish and colloquial phrasings live here so retrieval matches the way
  -- people actually ask, without the model having to translate first.
  keywords text[] not null default '{}',
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Maintained by trigger rather than as a generated column: array_to_string is
-- not immutable, so Postgres refuses it in a generation expression.
alter table public.assistant_knowledge_base
  add column if not exists search_vector tsvector;

create or replace function public.assistant_knowledge_base_vector()
returns trigger language plpgsql set search_path = public as $$
begin
  -- Question and keywords weigh heaviest: they are how people phrase the ask.
  new.search_vector :=
    setweight(to_tsvector('simple', coalesce(new.question, '')), 'A') ||
    setweight(
      to_tsvector('simple', array_to_string(coalesce(new.keywords, '{}'), ' ')),
      'A'
    ) ||
    setweight(to_tsvector('simple', coalesce(new.answer, '')), 'B');
  return new;
end;
$$;

drop trigger if exists assistant_knowledge_base_vector on public.assistant_knowledge_base;
create trigger assistant_knowledge_base_vector
before insert or update of question, answer, keywords
on public.assistant_knowledge_base
for each row execute procedure public.assistant_knowledge_base_vector();

create index if not exists assistant_knowledge_base_search_idx
  on public.assistant_knowledge_base using gin (search_vector);
create index if not exists assistant_knowledge_base_topic_idx
  on public.assistant_knowledge_base (topic);

create or replace function public.touch_assistant_knowledge_base()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists assistant_knowledge_base_touch on public.assistant_knowledge_base;
create trigger assistant_knowledge_base_touch
before update on public.assistant_knowledge_base
for each row execute procedure public.touch_assistant_knowledge_base();

alter table public.assistant_knowledge_base enable row level security;

revoke all on public.assistant_knowledge_base from public, anon;
grant select on public.assistant_knowledge_base to authenticated;

-- Readable by any signed-in caller whose lane the chunk is addressed to;
-- writable only by internal admins, who own policy wording.
drop policy if exists assistant_knowledge_base_read on public.assistant_knowledge_base;
create policy assistant_knowledge_base_read
on public.assistant_knowledge_base for select to authenticated
using (
  audience && array[public.requester_admin_lane()]
  or (public.is_admin() and 'admin' = any(audience))
  or public.is_internal_admin()
);

drop policy if exists assistant_knowledge_base_write on public.assistant_knowledge_base;
create policy assistant_knowledge_base_write
on public.assistant_knowledge_base for all to authenticated
using (public.is_internal_admin())
with check (public.is_internal_admin());

-- ---------------------------------------------------------------------------
-- Retrieval. Returns at most three chunks, ranked, already filtered to what the
-- caller may see -- so the edge function never has to decide who gets what.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_knowledge_search(
  p_query text,
  p_limit integer default 3
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  limit_value integer := least(greatest(coalesce(p_limit, 3), 1), 5);
  query_text text := coalesce(nullif(trim(p_query), ''), '');
  lane_value text;
  terms text[];
  search_query tsquery;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if query_text = '' then
    return jsonb_build_object('chunks', '[]'::jsonb);
  end if;

  -- Terms are OR-ed, not AND-ed. A real question mixes languages and
  -- redundant words -- "magkano bayad down payment" -- and requiring every
  -- term to appear would return nothing at all. ts_rank still floats the
  -- chunk that matches the most terms to the top, which is the behaviour we
  -- actually want: best effort, ranked, never empty out of pedantry.
  select array_agg(token)
  into terms
  from (
    select distinct lower(token) as token
    from unnest(regexp_split_to_array(query_text, '[^[:alnum:]]+')) as token
    where char_length(token) >= 2
    limit 12
  ) cleaned;

  if terms is null or array_length(terms, 1) is null then
    return jsonb_build_object('chunks', '[]'::jsonb);
  end if;

  -- Quoting each lexeme keeps user text out of tsquery syntax entirely.
  search_query := to_tsquery(
    'simple',
    array_to_string(array(select quote_literal(t) from unnest(terms) t), ' | ')
  );

  lane_value := public.requester_admin_lane();

  return jsonb_build_object(
    'chunks', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug', matched.slug,
          'topic', matched.topic,
          'question', matched.question,
          'answer', matched.answer
        ) order by matched.rank desc
      )
      from (
        select
          kb.slug,
          kb.topic,
          kb.question,
          kb.answer,
          ts_rank(kb.search_vector, search_query) as rank
        from public.assistant_knowledge_base kb
        where kb.search_vector @@ search_query
          and (
            kb.audience && array[lane_value]
            or (public.is_admin() and 'admin' = any(kb.audience))
          )
        order by rank desc
        limit limit_value
      ) matched
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.assistant_knowledge_search(text, integer) from public, anon;
grant execute on function public.assistant_knowledge_search(text, integer) to authenticated;
revoke execute on function public.touch_assistant_knowledge_base() from public, anon, authenticated;
revoke execute on function public.assistant_knowledge_base_vector() from public, anon, authenticated;

notify pgrst, 'reload schema';
