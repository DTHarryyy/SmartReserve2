-- Knowledge search matches ANY term, not all of them.
--
-- The seed phrases questions the way a user would type them ("magkano ang
-- bayad", "how do I cancel"), so an AND query drops a chunk the moment the
-- user adds one word the chunk does not contain. OR plus ts_rank keeps the
-- best match at the top and lets near misses through, which is the behaviour
-- a FAQ lookup wants.
--
-- Terms are quoted through quote_literal before reaching to_tsquery: the
-- query text is user input, and to_tsquery parses its argument as an
-- expression.

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

notify pgrst, 'reload schema';
