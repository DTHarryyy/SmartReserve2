-- Read-only projections for the AI assistant's tool layer.
--
-- The assistant's cloud model is never handed a table, a row, or a query. It
-- calls a fixed set of tools, and each one resolves to exactly one of the
-- functions below. Three properties make that safe and cheap:
--
--   1. Every function filters on auth.uid() (or delegates to the existing
--      can_access_reservation helper), so the edge function can call them with
--      the caller's own JWT and row-level security does the authorization. The
--      service-role key is never used for a chatbot read: can_manage_facility()
--      is deliberately broad and admin_lane() is null for non-admins, so a
--      service-role read would bypass the only thing separating the internal
--      and external lanes.
--
--   2. Each returns a narrow, already-computed shape rather than a whole row.
--      Balances, deadlines and statuses arrive finished, so the model restates
--      them instead of calculating -- and the prompt stays small, which is the
--      difference between a few hundred tokens per answer and a few thousand.
--
--   3. Row counts are capped in the function, not by the caller, so no prompt
--      argument can make an answer expensive.
--
-- These deliberately do NOT re-implement pricing, availability or permit
-- readiness. Those live in get_reservation_quote, facility_busy_windows and
-- get_reservation_permit_readiness, and drift between two copies of a money
-- rule is worse than an extra round trip.

-- ---------------------------------------------------------------------------
-- assistant_my_reservations: the caller's own reservations, one compact row
-- each. 'upcoming' is what "what reservations do I have" means in practice;
-- 'active' includes anything still needing the requester's attention.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_my_reservations(
  p_scope text default 'upcoming',
  p_limit integer default 10
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  scope_value text := coalesce(nullif(trim(p_scope), ''), 'upcoming');
  limit_value integer := least(greatest(coalesce(p_limit, 10), 1), 10);
  rows_value jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if scope_value not in ('upcoming', 'active', 'recent') then
    raise exception using errcode = '22023', message = 'Unknown reservation scope';
  end if;

  select coalesce(jsonb_agg(row_value order by starts_at_value), '[]'::jsonb)
  into rows_value
  from (
    select
      jsonb_build_object(
        'id', r.id,
        'facility_name', r.facility_name,
        'starts_at', occ.starts_at,
        'ends_at', occ.ends_at,
        'lifecycle_status', r.reservation_status,
        'booking_stage', occ.lifecycle_stage,
        'total_amount_centavos', r.total_amount_centavos,
        'outstanding_amount_centavos', greatest(
          0,
          r.total_amount_centavos - coalesce((
            select sum(p.amount_centavos)
            from public.payment_transactions p
            where p.request_id = r.id
              and p.status = 'verified'
              and p.purpose <> 'refund'
          ), 0)
        )
      ) as row_value,
      occ.starts_at as starts_at_value
    from public.reservation_requests r
    join lateral (
      -- One representative occurrence per request: the next one that still
      -- matters, so a weekly series reads as a single upcoming booking.
      select o.starts_at, o.ends_at, o.lifecycle_stage
      from public.reservation_occurrences o
      where o.request_id = r.id
        and o.booking_state not in ('cancelled', 'expired')
      order by
        case when o.starts_at >= now() then 0 else 1 end,
        case when o.starts_at >= now() then o.starts_at end asc,
        o.starts_at desc
      limit 1
    ) occ on true
    where r.requester_id = auth.uid()
      and case scope_value
        when 'upcoming' then
          occ.starts_at >= now()
          and r.reservation_status not in ('cancelled', 'declined', 'expired')
        when 'active' then
          r.reservation_status in (
            'pending_approval', 'changes_requested', 'awaiting_payment', 'confirmed'
          )
        else true
      end
    order by
      case when scope_value = 'recent' then occ.starts_at end desc,
      occ.starts_at asc
    limit limit_value
  ) ranked;

  return jsonb_build_object('scope', scope_value, 'reservations', rows_value);
end;
$$;

-- ---------------------------------------------------------------------------
-- assistant_reservation_detail: one reservation, with payment and permit state
-- folded in. Merging them here means "what's the status, how much do I owe and
-- can I download the permit" costs one round trip rather than three.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_reservation_detail(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  verified_value integer;
  permit_row public.reservation_permits%rowtype;
  next_start timestamptz;
  next_end timestamptz;
  cancellable boolean;
begin
  select * into request_row
  from public.reservation_requests
  where id = p_request_id;

  -- Ownership, not a prompt instruction, is what stops cross-account reads.
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  select coalesce(sum(amount_centavos), 0) into verified_value
  from public.payment_transactions
  where request_id = p_request_id
    and status = 'verified'
    and purpose <> 'refund';

  select starts_at, ends_at into next_start, next_end
  from public.reservation_occurrences
  where request_id = p_request_id
    and booking_state not in ('cancelled', 'expired')
  order by
    case when starts_at >= now() then 0 else 1 end,
    case when starts_at >= now() then starts_at end asc,
    starts_at desc
  limit 1;

  select * into permit_row
  from public.reservation_permits
  where request_id = p_request_id
    and status = 'active'
  order by version desc
  limit 1;

  -- Mirrors the requester cancellation rule: a future, still-live occurrence
  -- on a reservation that has not reached a terminal state. There is no
  -- cancellation window and no fee -- only "has it started yet".
  select exists (
    select 1
    from public.reservation_occurrences o
    where o.request_id = p_request_id
      and o.starts_at > now()
      and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped')
  ) and request_row.reservation_status in ('awaiting_payment', 'confirmed')
  into cancellable;

  return jsonb_build_object(
    'id', request_row.id,
    'facility_name', request_row.facility_name,
    'facility_building', request_row.facility_building,
    'starts_at', next_start,
    'ends_at', next_end,
    'lifecycle_status', request_row.reservation_status,
    'headcount', request_row.headcount,
    'purpose', request_row.purpose,
    'total_amount_centavos', request_row.total_amount_centavos,
    'verified_amount_centavos', verified_value,
    'outstanding_amount_centavos',
      greatest(0, request_row.total_amount_centavos - verified_value),
    'required_down_payment_centavos', request_row.required_down_payment_centavos,
    'payment_due_at', request_row.payment_due_at,
    'balance_due_at', request_row.balance_due_at,
    'payment_exemption', request_row.payment_exemption,
    'can_cancel', coalesce(cancellable, false),
    -- The storage policy, not this flag, is the real gate; it is reported here
    -- so the assistant never promises a download the bucket will refuse.
    'permit_downloadable', coalesce(
      permit_row.generation_status = 'ready'
        and permit_row.delivery_status = 'sent'
        and permit_row.storage_path is not null,
      false
    ),
    'permit_number', permit_row.permit_number
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- assistant_facility_summary: the facts needed to answer "can I book it, when
-- is it open, what does it have". Amenity rows carry name and price only.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_facility_summary(p_facility_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  facility_row public.facilities%rowtype;
  lane_value text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into facility_row
  from public.facilities
  where id = p_facility_id and archived_at is null;

  if facility_row.id is null then
    raise exception using errcode = '22023', message = 'Facility not found';
  end if;

  lane_value := public.requester_admin_lane();

  return jsonb_build_object(
    'id', facility_row.id,
    'name', facility_row.name,
    'building', facility_row.building,
    'room', facility_row.room,
    'category', facility_row.category,
    'capacity', facility_row.capacity,
    'status', facility_row.status,
    'open_time', facility_row.open_time,
    'close_time', facility_row.close_time,
    'open_days', facility_row.open_days,
    'max_duration_minutes', facility_row.max_duration_minutes,
    'advance_booking_days', facility_row.advance_booking_days,
    'booking_buffer_minutes', facility_row.booking_buffer_minutes,
    'down_payment_percent', facility_row.down_payment_percent,
    'bookable_for_me',
      facility_row.status = 'active'
      and facility_row.public_listing
      and facility_row.facility_classification in ('shared', lane_value)
      and public.has_active_admin_in_lane(lane_value),
    'booking_block_reason', case
      when facility_row.status <> 'active' then 'facility_inactive'
      when facility_row.facility_classification not in ('shared', lane_value)
        then 'facility_not_available_for_account_type'
      when not public.has_active_admin_in_lane(lane_value)
        then 'no_active_' || lane_value || '_admin'
      else null
    end,
    'amenities', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'name', a.name,
          'price_centavos', a.price_centavos,
          'pricing_unit', a.pricing_unit
        ) order by a.name
      )
      from public.facility_amenities a
      where a.facility_id = p_facility_id and a.enabled
    ), '[]'::jsonb),
    'rating_average', (
      select rating_average from public.facility_rating_stats
      where facility_id = p_facility_id
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- assistant_recommend_facilities: the hard filter for "suggest a facility for
-- 200 people".
--
-- Deliberately a filter, not a ranker. The ordering that decides which room is
-- "best" lives in one place -- assistant_recommendation.dart -- so the reason
-- the assistant gives can never diverge from the order it presents. This
-- function's job is to guarantee that nothing the caller cannot actually book
-- reaches that ranker.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_recommend_facilities(
  p_min_capacity integer default null,
  p_category text default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  lane_value text;
  limit_value integer := least(greatest(coalesce(p_limit, 20), 1), 20);
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  lane_value := public.requester_admin_lane();

  return jsonb_build_object(
    'lane', lane_value,
    'facilities', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', f.id,
          'name', f.name,
          'building', f.building,
          'room', f.room,
          'category', f.category,
          'capacity', f.capacity,
          'amenities', coalesce((
            select jsonb_agg(a.name order by a.name)
            from public.facility_amenities a
            where a.facility_id = f.id and a.enabled
          ), '[]'::jsonb),
          'rating_average', s.rating_average
        ) order by f.capacity asc, f.name asc
      )
      from public.facilities f
      left join public.facility_rating_stats s on s.facility_id = f.id
      where f.archived_at is null
        and f.status = 'active'
        and f.public_listing
        and f.facility_classification in ('shared', lane_value)
        and (p_min_capacity is null or f.capacity >= p_min_capacity)
        and (p_category is null or f.category = p_category)
        and public.has_active_admin_in_lane(lane_value)
      limit limit_value
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- assistant_equipment_availability: what a facility offers, and whether each
-- item is already spoken for in an overlapping live reservation.
--
-- SmartReserve tracks no stock counts anywhere, so this reports "requested
-- elsewhere at that time", never "3 of 5 left". Saying otherwise would be an
-- invented number.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_equipment_availability(
  p_facility_id uuid,
  p_from timestamptz default null,
  p_to timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  window_from timestamptz := coalesce(p_from, now());
  window_to timestamptz := coalesce(p_to, coalesce(p_from, now()) + interval '1 day');
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if window_to <= window_from then
    raise exception using errcode = '22023', message = 'Invalid window';
  end if;
  -- Bound the scan the same way the calendar RPCs do.
  if window_to > window_from + interval '120 days' then
    window_to := window_from + interval '120 days';
  end if;

  return jsonb_build_object(
    'facility_id', p_facility_id,
    'from', window_from,
    'to', window_to,
    'tracks_stock_levels', false,
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'name', a.name,
          'price_centavos', a.price_centavos,
          'pricing_unit', a.pricing_unit,
          'requested_elsewhere', exists (
            select 1
            from public.reservation_amenities ra
            join public.reservation_requests r on r.id = ra.request_id
            join public.reservation_occurrences o on o.request_id = r.id
            where ra.facility_amenity_id = a.id
              and r.reservation_status in ('awaiting_payment', 'confirmed')
              and o.booking_state in ('held', 'booked')
              and o.starts_at < window_to
              and o.ends_at > window_from
          )
        ) order by a.name
      )
      from public.facility_amenities a
      where a.facility_id = p_facility_id and a.enabled
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- assistant_my_announcements: SmartReserve has no announcements table. What it
-- has is the caller's own notification feed plus facility maintenance state,
-- which together answer "is there anything I should know about". Nothing here
-- reaches beyond the caller's own rows.
-- ---------------------------------------------------------------------------
create or replace function public.assistant_my_announcements(
  p_limit integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  limit_value integer := least(greatest(coalesce(p_limit, 5), 1), 10);
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  return jsonb_build_object(
    'notices', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'title', n.title,
          'body', left(n.body, 200),
          'kind', n.kind,
          'unread', n.read_at is null,
          'created_at', n.created_at
        ) order by n.created_at desc
      )
      from (
        select *
        from public.app_notifications
        where recipient_id = auth.uid()
        order by read_at nulls first, created_at desc
        limit limit_value
      ) n
    ), '[]'::jsonb),
    -- Only facilities the caller actually has a live booking at: a global
    -- maintenance list would be noise, and longer prompts for no benefit.
    'facility_advisories', coalesce((
      select jsonb_agg(distinct jsonb_build_object(
        'facility_name', f.name,
        'status', f.status
      ))
      from public.facilities f
      join public.reservation_requests r on r.facility_id = f.id
      join public.reservation_occurrences o on o.request_id = r.id
      where r.requester_id = auth.uid()
        and o.starts_at >= now()
        and o.booking_state in ('held', 'booked')
        and f.status <> 'active'
    ), '[]'::jsonb)
  );
end;
$$;

-- Grants. Mirrors every other RPC in this schema: nothing for anon, execute
-- for signed-in callers, and authorization enforced inside the body.
revoke execute on function public.assistant_my_reservations(text, integer) from public, anon;
revoke execute on function public.assistant_reservation_detail(uuid) from public, anon;
revoke execute on function public.assistant_facility_summary(uuid) from public, anon;
revoke execute on function public.assistant_recommend_facilities(integer, text, integer) from public, anon;
revoke execute on function public.assistant_equipment_availability(uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.assistant_my_announcements(integer) from public, anon;

grant execute on function public.assistant_my_reservations(text, integer) to authenticated;
grant execute on function public.assistant_reservation_detail(uuid) to authenticated;
grant execute on function public.assistant_facility_summary(uuid) to authenticated;
grant execute on function public.assistant_recommend_facilities(integer, text, integer) to authenticated;
grant execute on function public.assistant_equipment_availability(uuid, timestamptz, timestamptz) to authenticated;
grant execute on function public.assistant_my_announcements(integer) to authenticated;

notify pgrst, 'reload schema';
