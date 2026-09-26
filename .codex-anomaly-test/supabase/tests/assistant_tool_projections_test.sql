-- The assistant's tool layer is only as safe as these functions. The model can
-- be talked into asking for anything, so what matters is not what it asks but
-- what the database will hand back: these tests pin the answer to "the caller's
-- own rows, capped, and nothing else".

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(16);

-- One requester with a reservation, and any other account to impersonate. The
-- second actor deliberately needs no reservation of its own: the point is that
-- being signed in is not the same as being the owner.
create temp table assistant_projection_actors as
with owner as (
  select requester_id, id as request_id
  from public.reservation_requests
  where requester_id is not null
  order by created_at desc
  limit 1
)
select
  owner.requester_id as owner_a,
  owner.request_id as request_a,
  (
    select p.id from public.profiles p
    where p.id <> owner.requester_id
    order by p.created_at
    limit 1
  ) as owner_b
from owner;

select ok(
  (select owner_a is not null and owner_b is not null
     from assistant_projection_actors),
  'the fixture found an owner and a second, unrelated account'
);

-- ---------------------------------------------------------------------------
-- Existence and shape
-- ---------------------------------------------------------------------------
select has_function('public', 'assistant_my_reservations', array['text', 'integer'],
  'assistant_my_reservations exists');
select has_function('public', 'assistant_reservation_detail', array['uuid'],
  'assistant_reservation_detail exists');
select has_function('public', 'assistant_facility_summary', array['uuid'],
  'assistant_facility_summary exists');
select has_function('public', 'assistant_recommend_facilities',
  array['integer', 'text', 'integer'],
  'assistant_recommend_facilities exists');
select has_function('public', 'assistant_equipment_availability',
  array['uuid', 'timestamptz', 'timestamptz'],
  'assistant_equipment_availability exists');
select has_function('public', 'assistant_my_announcements', array['integer'],
  'assistant_my_announcements exists');

-- ---------------------------------------------------------------------------
-- anon must not reach the tool layer at all. A chatbot request always carries a
-- session; an unauthenticated one is a bug, not a degraded mode.
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.assistant_my_reservations(text, integer)', 'execute'),
  'anon cannot execute assistant_my_reservations'
);
select ok(
  not has_function_privilege('anon', 'public.assistant_reservation_detail(uuid)', 'execute'),
  'anon cannot execute assistant_reservation_detail'
);
select ok(
  has_function_privilege('authenticated', 'public.assistant_reservation_detail(uuid)', 'execute'),
  'signed-in callers can execute the detail projection'
);

-- ---------------------------------------------------------------------------
-- User scoping
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claim.sub',
  (select owner_a::text from assistant_projection_actors), true);

select is(
  (
    select count(*)
    from jsonb_array_elements(
      public.assistant_my_reservations('recent', 10) -> 'reservations'
    ) row_value
    join public.reservation_requests r
      on r.id = (row_value ->> 'id')::uuid
    where r.requester_id <> (select owner_a from assistant_projection_actors)
  ),
  0::bigint,
  'assistant_my_reservations returns only the caller''s own reservations'
);

select ok(
  jsonb_array_length(
    public.assistant_my_reservations('recent', 999) -> 'reservations'
  ) <= 10,
  'the row cap holds even when the caller asks for more'
);

select is(
  public.assistant_reservation_detail(
    (select request_a from assistant_projection_actors)
  ) ->> 'id',
  (select request_a::text from assistant_projection_actors),
  'a requester can read their own reservation detail'
);

-- The important one: the same call, as somebody else, must raise rather than
-- return. This is what stops a prompt injection from becoming a data leak.
-- Switch identity first, then assert -- pgTAP evaluates its argument as SQL
-- text, so the session must already be the other user when it runs.
select set_config('request.jwt.claim.sub',
  (select owner_b::text from assistant_projection_actors), true);

select throws_ok(
  format(
    'select public.assistant_reservation_detail(%L::uuid)',
    (select request_a from assistant_projection_actors)
  ),
  '42501',
  null,
  'another account cannot read that reservation'
);

-- ---------------------------------------------------------------------------
-- Bounds and invariants
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub',
  (select owner_a::text from assistant_projection_actors), true);

select throws_ok(
  $$select public.assistant_my_reservations('everything', 5)$$,
  '22023',
  null,
  'an unknown scope is rejected rather than silently widened'
);

select is(
  jsonb_array_length(
    public.assistant_recommend_facilities(999999, null, 20) -> 'facilities'
  ),
  0,
  'no facility is suggested that cannot hold the party'
);

-- SmartReserve tracks no stock counts anywhere, so the tool must say so rather
-- than let the model imagine "3 of 5 left".
select is(
  (
    select public.assistant_equipment_availability(f.id, now(), now() + interval '1 day')
             ->> 'tracks_stock_levels'
    from public.facilities f
    where f.archived_at is null
    order by f.created_at
    limit 1
  ),
  'false',
  'equipment availability never claims to know stock levels'
);

select * from finish();
rollback;
