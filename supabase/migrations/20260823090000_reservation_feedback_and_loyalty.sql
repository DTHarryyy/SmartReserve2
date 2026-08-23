-- Reservation feedback and loyalty points.
--
-- Design decisions worth reading before touching this file:
--
-- 1. `reservation_status = 'completed'` is reachable with zero attended
--    occurrences (an all-no-show series also lands there -- see the overlay
--    in 20260822160000_atomic_requester_cancellation.sql). Every eligibility
--    check below additionally requires an occurrence with
--    lifecycle_stage = 'completed'. Never trust reservation_status alone.
--
-- 2. Rating aggregates live on a SIBLING table (facility_rating_stats), not
--    as columns on public.facilities. Two triggers on facilities make that
--    actively harmful: facilities_set_actor (before insert/update) would
--    rewrite "last changed by" to the reviewing student on every rating and
--    reorder the admin facility list (sorted by updated_at desc), and
--    facilities_capture_audit (after insert/update) would write an audit
--    row per star rating.
--
-- 3. Points are awarded from a trigger on reservation_requests, not by
--    editing reservation_action / reservation_action_unscoped. Those
--    functions have been create-or-replace'd by four separate migrations;
--    a change buried inside them risks being silently dropped by the next
--    rewrite. A trigger on the status column is edit-once, covers
--    bulk_approve_reservations and any future path, and rolls back with
--    the action that fired it.
--
-- 4. The completion award is NOT clawed back when undo_reservation_action
--    reverses a completion. Undo's 8-second window exists to fix a
--    misclick, so the reservation is normally re-completed seconds later;
--    a claw-back would have to delete a ledger row (breaking append-only)
--    and would then permanently block the re-award via the idempotency
--    index. The correction path for a genuine over-award is a negative
--    admin_adjustment, which is exactly what that transaction type is for.
--
-- 5. Every write to loyalty_transactions / reservation_feedback goes
--    through a security definer RPC. No table below has an insert, update,
--    or delete grant for any role -- that is the strongest available
--    guarantee that a client cannot forge a review, mint points, or edit a
--    balance directly.

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table if not exists public.reservation_feedback (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null unique
    references public.reservation_requests(id) on delete cascade,
  facility_id uuid not null references public.facilities(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  cleanliness_rating smallint check (cleanliness_rating between 1 and 5),
  condition_rating smallint check (condition_rating between 1 and 5),
  equipment_rating smallint check (equipment_rating between 1 and 5),
  comment text not null default '' check (length(comment) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists reservation_feedback_facility_idx
  on public.reservation_feedback(facility_id, created_at desc);
create index if not exists reservation_feedback_user_idx
  on public.reservation_feedback(user_id, created_at desc);
create index if not exists reservation_feedback_rating_idx
  on public.reservation_feedback(rating, created_at desc);

create table if not exists public.facility_rating_stats (
  facility_id uuid primary key references public.facilities(id) on delete cascade,
  rating_average numeric(3,2) check (rating_average is null or rating_average between 1 and 5),
  rating_count integer not null default 0 check (rating_count >= 0),
  updated_at timestamptz not null default now()
);

insert into public.facility_rating_stats(facility_id)
select id from public.facilities
on conflict (facility_id) do nothing;

-- Every future facility gets a stats row too, so the PostgREST embed on
-- facilities() is never absent for a brand-new listing.
create or replace function public.seed_facility_rating_stats()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.facility_rating_stats(facility_id)
  values (new.id)
  on conflict (facility_id) do nothing;
  return null;
end;
$$;

drop trigger if exists facilities_seed_rating_stats on public.facilities;
create trigger facilities_seed_rating_stats
after insert on public.facilities
for each row execute procedure public.seed_facility_rating_stats();

create table if not exists public.loyalty_point_rules (
  transaction_type text primary key
    check (transaction_type in ('reservation_completed','feedback_submitted')),
  points integer not null check (points > 0),
  updated_at timestamptz not null default now()
);
insert into public.loyalty_point_rules(transaction_type, points)
values ('reservation_completed', 10), ('feedback_submitted', 5)
on conflict (transaction_type) do nothing;

create table if not exists public.loyalty_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  points integer not null check (points <> 0 and abs(points) <= 100000),
  transaction_type text not null check (transaction_type in
    ('reservation_completed','feedback_submitted','reward_redeemed','admin_adjustment')),
  source_type text not null check (source_type in ('reservation','feedback','redemption','admin')),
  source_id uuid,
  description text not null default '' check (length(description) <= 200),
  actor_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint loyalty_transactions_sign check (
    (transaction_type in ('reservation_completed','feedback_submitted') and points > 0)
    or (transaction_type = 'reward_redeemed' and points < 0)
    or transaction_type = 'admin_adjustment'
  ),
  constraint loyalty_transactions_source check (
    transaction_type = 'admin_adjustment' or source_id is not null
  )
);

-- THE idempotency guarantee. A completed reservation, a feedback
-- submission, or a redemption can each produce exactly one ledger row no
-- matter how many times the write is attempted (refresh, restart, retried
-- request, undo/redo, double submit).
create unique index if not exists loyalty_transactions_source_idx
  on public.loyalty_transactions(transaction_type, source_type, source_id)
  where source_id is not null;
create index if not exists loyalty_transactions_user_idx
  on public.loyalty_transactions(user_id, created_at desc);

create table if not exists public.loyalty_rewards (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 3 and 80),
  description text not null default '' check (length(description) <= 400),
  points_cost integer not null check (points_cost between 1 and 100000),
  active boolean not null default true,
  stock integer check (stock is null or stock >= 0),
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.loyalty_redemptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  reward_id uuid not null references public.loyalty_rewards(id) on delete restrict,
  reward_name text not null,
  points_spent integer not null check (points_spent > 0),
  status text not null default 'issued' check (status in ('issued','fulfilled','cancelled')),
  redemption_code text not null unique
    default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  created_at timestamptz not null default now(),
  fulfilled_at timestamptz,
  fulfilled_by uuid references public.profiles(id) on delete set null
);
create index if not exists loyalty_redemptions_user_idx
  on public.loyalty_redemptions(user_id, created_at desc);

-- Low-rating admin alerts are repeat-safe, mirroring
-- app_notifications_single_reminder_idx.
create unique index if not exists app_notifications_single_low_rating_idx
  on public.app_notifications(recipient_id, request_id, kind)
  where kind = 'feedback_low_rating';

-- ---------------------------------------------------------------------
-- Award plumbing
-- ---------------------------------------------------------------------

create or replace function public.loyalty_points_for(p_transaction_type text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select points from public.loyalty_point_rules where transaction_type = p_transaction_type;
$$;

create or replace function public.award_reservation_completion_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  awarded_id uuid;
  award_points integer;
begin
  if new.reservation_status = 'completed'
     and old.reservation_status is distinct from 'completed'
     and new.requester_id is not null
     and exists (
       select 1 from public.reservation_occurrences
       where request_id = new.id and lifecycle_stage = 'completed'
     )
  then
    award_points := public.loyalty_points_for('reservation_completed');
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description
    ) values (
      new.requester_id, award_points, 'reservation_completed',
      'reservation', new.id, 'Completed reservation - ' || new.facility_name
    )
    on conflict (transaction_type, source_type, source_id) do nothing
    returning id into awarded_id;

    if awarded_id is not null then
      insert into public.app_notifications(recipient_id, request_id, kind, title, body)
      values (
        new.requester_id, new.id, 'loyalty_earned',
        '+' || award_points || ' points',
        'Thanks for using ' || new.facility_name || '.'
      );
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists reservation_requests_award_loyalty on public.reservation_requests;
create trigger reservation_requests_award_loyalty
after update of reservation_status on public.reservation_requests
for each row execute procedure public.award_reservation_completion_points();

create or replace function public.refresh_facility_rating_stats()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target uuid := coalesce(new.facility_id, old.facility_id);
begin
  insert into public.facility_rating_stats(facility_id, rating_average, rating_count, updated_at)
  select target, round(avg(rating)::numeric, 2), count(*), now()
  from public.reservation_feedback
  where facility_id = target
  on conflict (facility_id) do update set
    rating_average = excluded.rating_average,
    rating_count = excluded.rating_count,
    updated_at = excluded.updated_at;
  return null;
end;
$$;

drop trigger if exists reservation_feedback_refresh_rating on public.reservation_feedback;
create trigger reservation_feedback_refresh_rating
after insert or delete or update of rating, facility_id on public.reservation_feedback
for each row execute procedure public.refresh_facility_rating_stats();

-- ---------------------------------------------------------------------
-- Feedback RPC
-- ---------------------------------------------------------------------

create or replace function public.submit_reservation_feedback(
  p_reservation_id uuid,
  p_rating integer,
  p_comment text default '',
  p_cleanliness integer default null,
  p_condition integer default null,
  p_equipment integer default null
) returns public.reservation_feedback
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.reservation_feedback%rowtype;
  awarded_id uuid;
  award_points integer;
  clean_comment text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Choose a rating from 1 to 5';
  end if;
  if p_cleanliness is not null and p_cleanliness not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Cleanliness rating must be between 1 and 5';
  end if;
  if p_condition is not null and p_condition not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Condition rating must be between 1 and 5';
  end if;
  if p_equipment is not null and p_equipment not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Equipment rating must be between 1 and 5';
  end if;
  clean_comment := trim(coalesce(p_comment, ''));
  if length(clean_comment) > 500 then
    raise exception using errcode = '22023', message = 'Keep your comment under 500 characters';
  end if;

  select * into request_row from public.reservation_requests
  where id = p_reservation_id for update;

  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Feedback is limited to the person who booked';
  end if;
  if request_row.reservation_status <> 'completed'
     or not exists (
       select 1 from public.reservation_occurrences
       where request_id = p_reservation_id and lifecycle_stage = 'completed'
     ) then
    raise exception using errcode = '22023', message = 'Feedback opens once the reservation is completed';
  end if;

  begin
    insert into public.reservation_feedback(
      reservation_id, facility_id, user_id, rating,
      cleanliness_rating, condition_rating, equipment_rating, comment
    ) values (
      p_reservation_id, request_row.facility_id, auth.uid(), p_rating,
      p_cleanliness, p_condition, p_equipment, clean_comment
    )
    returning * into result;
  exception when unique_violation then
    raise exception using errcode = '23505', message = 'You already left feedback for this reservation';
  end;

  award_points := public.loyalty_points_for('feedback_submitted');
  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description
  ) values (
    auth.uid(), award_points, 'feedback_submitted', 'feedback',
    result.id, 'Feedback for ' || request_row.facility_name
  )
  on conflict (transaction_type, source_type, source_id) do nothing
  returning id into awarded_id;

  if awarded_id is not null then
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    values (
      auth.uid(), p_reservation_id, 'loyalty_earned',
      '+' || award_points || ' points',
      'Thanks for rating ' || request_row.facility_name || '.'
    );
  end if;

  if p_rating <= 2 then
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    select a.id, p_reservation_id, 'feedback_low_rating',
           p_rating || ' star rating for ' || request_row.facility_name,
           coalesce(nullif(clean_comment, ''), 'No comment left.')
    from public.profiles a
    where a.account_status = 'active'
      and (
        a.role = 'internal_admin'
        or (a.role = 'external_admin' and public.can_manage_facility(request_row.facility_id, a.id))
      )
    on conflict (recipient_id, request_id, kind) where kind = 'feedback_low_rating' do nothing;
  end if;

  perform public.reservation_event(
    p_reservation_id, 'left feedback', null,
    jsonb_build_object('rating', p_rating), null, false
  );

  return result;
end;
$$;

revoke all on function public.submit_reservation_feedback(uuid, integer, text, integer, integer, integer)
  from public, anon;
grant execute on function public.submit_reservation_feedback(uuid, integer, text, integer, integer, integer)
  to authenticated;

-- ---------------------------------------------------------------------
-- Balance and redemption
-- ---------------------------------------------------------------------

create or replace function public.loyalty_balance(p_user_id uuid default auth.uid())
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_user_id <> auth.uid() and not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Not authorized to view this balance';
  end if;
  return coalesce(
    (select sum(points) from public.loyalty_transactions where user_id = p_user_id), 0
  )::integer;
end;
$$;

revoke all on function public.loyalty_balance(uuid) from public, anon;
grant execute on function public.loyalty_balance(uuid) to authenticated;

create or replace function public.redeem_loyalty_reward(p_reward_id uuid)
returns public.loyalty_redemptions
language plpgsql
security definer
set search_path = public
as $$
declare
  reward public.loyalty_rewards%rowtype;
  redemption public.loyalty_redemptions%rowtype;
  balance integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Please sign in again';
  end if;

  -- Lock order is ALWAYS profiles -> loyalty_rewards. A single profile row
  -- locked in a fixed order relative to loyalty_rewards makes deadlock
  -- structurally impossible.
  perform 1 from public.profiles where id = auth.uid() for update;

  select * into reward from public.loyalty_rewards where id = p_reward_id for update;

  if reward.id is null or not reward.active then
    raise exception using errcode = '22023', message = 'This reward is not available';
  end if;
  if reward.stock is not null and reward.stock < 1 then
    raise exception using errcode = '22023', message = 'This reward is out of stock';
  end if;

  -- Inlined rather than loyalty_balance(): must run as a fresh statement
  -- under the lock above so a concurrent redemption's committed deduction
  -- is visible before we check affordability.
  select coalesce(sum(points), 0)::integer into balance
  from public.loyalty_transactions where user_id = auth.uid();

  if balance < reward.points_cost then
    raise exception using errcode = '22023',
      message = 'You need ' || (reward.points_cost - balance) || ' more points for this reward';
  end if;

  insert into public.loyalty_redemptions(user_id, reward_id, reward_name, points_spent)
  values (auth.uid(), reward.id, reward.name, reward.points_cost)
  returning * into redemption;

  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description
  ) values (
    auth.uid(), -reward.points_cost, 'reward_redeemed', 'redemption', redemption.id, reward.name
  );

  if reward.stock is not null then
    update public.loyalty_rewards set stock = stock - 1, updated_at = now() where id = reward.id;
  end if;

  insert into public.app_notifications(recipient_id, kind, title, body)
  values (
    auth.uid(), 'loyalty_redeemed', 'Reward redeemed',
    reward.name || ' - code ' || redemption.redemption_code
  );

  return redemption;
end;
$$;

revoke all on function public.redeem_loyalty_reward(uuid) from public, anon;
grant execute on function public.redeem_loyalty_reward(uuid) to authenticated;

create or replace function public.adjust_loyalty_points(
  p_user_id uuid,
  p_points integer,
  p_reason text
) returns public.loyalty_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  ledger public.loyalty_transactions%rowtype;
  balance integer;
  clean_reason text;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_points is null or p_points = 0 then
    raise exception using errcode = '22023', message = 'Enter a nonzero point amount';
  end if;
  clean_reason := trim(coalesce(p_reason, ''));
  if clean_reason = '' then
    raise exception using errcode = '22023', message = 'A reason is required for a manual adjustment';
  end if;

  select * into actor from public.profiles where id = auth.uid();

  perform 1 from public.profiles where id = p_user_id for update;
  select * into target from public.profiles where id = p_user_id;
  if target.id is null then
    raise exception using errcode = 'P0002', message = 'User not found';
  end if;

  select coalesce(sum(points), 0)::integer into balance
  from public.loyalty_transactions where user_id = p_user_id;

  if balance + p_points < 0 then
    raise exception using errcode = '22023', message = 'This adjustment would take the balance below zero';
  end if;

  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description, actor_id
  ) values (
    p_user_id, p_points, 'admin_adjustment', 'admin', gen_random_uuid(),
    'Admin adjustment: ' || clean_reason, auth.uid()
  ) returning * into ledger;

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, after_values, material, source_type, source_id
  ) values (
    'account', p_user_id, coalesce(nullif(target.full_name, ''), target.email),
    auth.uid(), coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    'adjusted loyalty points', clean_reason,
    jsonb_build_object('points', p_points, 'balance', balance + p_points),
    true, 'loyalty_adjustment', ledger.id
  );

  insert into public.app_notifications(recipient_id, kind, title, body)
  values (
    p_user_id, 'loyalty_earned',
    (case when p_points > 0 then '+' else '' end) || p_points || ' points',
    'Admin adjustment: ' || clean_reason
  );

  return ledger;
end;
$$;

revoke all on function public.adjust_loyalty_points(uuid, integer, text) from public, anon;
grant execute on function public.adjust_loyalty_points(uuid, integer, text) to authenticated;

create or replace function public.save_loyalty_reward(
  p_id uuid default null,
  p_name text default null,
  p_description text default '',
  p_points_cost integer default null,
  p_active boolean default true,
  p_stock integer default null
) returns public.loyalty_rewards
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  result public.loyalty_rewards%rowtype;
  clean_name text;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  clean_name := trim(coalesce(p_name, ''));
  if length(clean_name) not between 3 and 80 then
    raise exception using errcode = '22023', message = 'Reward name must be between 3 and 80 characters';
  end if;
  if p_points_cost is null or p_points_cost not between 1 and 100000 then
    raise exception using errcode = '22023', message = 'Points cost must be between 1 and 100000';
  end if;
  if p_stock is not null and p_stock < 0 then
    raise exception using errcode = '22023', message = 'Stock cannot be negative';
  end if;

  select * into actor from public.profiles where id = auth.uid();

  if p_id is null then
    insert into public.loyalty_rewards(
      name, description, points_cost, active, stock, created_by, updated_by
    ) values (
      clean_name, coalesce(p_description, ''), p_points_cost, coalesce(p_active, true),
      p_stock, auth.uid(), auth.uid()
    ) returning * into result;

    insert into public.audit_entries(
      entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
      action, after_values, material, source_type, source_id
    ) values (
      'system', result.id, result.name, auth.uid(),
      coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
      'created a loyalty reward',
      jsonb_build_object('name', result.name, 'points_cost', result.points_cost),
      true, 'loyalty_reward', result.id
    );
  else
    update public.loyalty_rewards set
      name = clean_name,
      description = coalesce(p_description, ''),
      points_cost = p_points_cost,
      active = coalesce(p_active, active),
      stock = p_stock,
      updated_by = auth.uid(),
      updated_at = now()
    where id = p_id
    returning * into result;

    if result.id is null then
      raise exception using errcode = 'P0002', message = 'Reward not found';
    end if;

    insert into public.audit_entries(
      entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
      action, after_values, material, source_type, source_id
    ) values (
      'system', result.id, result.name, auth.uid(),
      coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
      'updated a loyalty reward',
      jsonb_build_object('name', result.name, 'points_cost', result.points_cost, 'active', result.active),
      true, 'loyalty_reward', gen_random_uuid()
    );
  end if;

  return result;
end;
$$;

revoke all on function public.save_loyalty_reward(uuid, text, text, integer, boolean, integer)
  from public, anon;
grant execute on function public.save_loyalty_reward(uuid, text, text, integer, boolean, integer)
  to authenticated;

create or replace function public.set_loyalty_reward_active(p_reward_id uuid, p_active boolean)
returns public.loyalty_rewards
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  result public.loyalty_rewards%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  select * into actor from public.profiles where id = auth.uid();
  update public.loyalty_rewards set active = p_active, updated_by = auth.uid(), updated_at = now()
  where id = p_reward_id
  returning * into result;
  if result.id is null then
    raise exception using errcode = 'P0002', message = 'Reward not found';
  end if;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, after_values, material, source_type, source_id
  ) values (
    'system', result.id, result.name, auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    case when p_active then 'activated a loyalty reward' else 'deactivated a loyalty reward' end,
    jsonb_build_object('active', p_active), true, 'loyalty_reward', gen_random_uuid()
  );
  return result;
end;
$$;

revoke all on function public.set_loyalty_reward_active(uuid, boolean) from public, anon;
grant execute on function public.set_loyalty_reward_active(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Read RPCs
-- ---------------------------------------------------------------------

create or replace function public.loyalty_my_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select jsonb_build_object(
    'balance', coalesce((select sum(points) from public.loyalty_transactions where user_id = auth.uid()), 0),
    'lifetime_earned', coalesce((select sum(points) from public.loyalty_transactions where user_id = auth.uid() and points > 0), 0),
    'lifetime_redeemed', coalesce((select sum(-points) from public.loyalty_transactions where user_id = auth.uid() and points < 0), 0),
    'rules', (select coalesce(jsonb_object_agg(transaction_type, points), '{}'::jsonb) from public.loyalty_point_rules),
    'transactions', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.created_at desc)
      from (
        select * from public.loyalty_transactions
        where user_id = auth.uid()
        order by created_at desc
        limit 50
      ) t
    ), '[]'::jsonb),
    'redemptions', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at desc)
      from (
        select * from public.loyalty_redemptions
        where user_id = auth.uid()
        order by created_at desc
        limit 20
      ) r
    ), '[]'::jsonb),
    'rewards', coalesce((
      select jsonb_agg(to_jsonb(w) order by w.points_cost)
      from (
        select * from public.loyalty_rewards
        where active
        order by points_cost
      ) w
    ), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

revoke all on function public.loyalty_my_summary() from public, anon;
grant execute on function public.loyalty_my_summary() to authenticated;

create or replace function public.loyalty_admin_balances(
  p_search text default null,
  p_limit integer default 100
) returns table(
  user_id uuid, full_name text, email text, balance bigint,
  lifetime_earned bigint, lifetime_redeemed bigint, last_activity_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  return query
  select p.id, p.full_name, p.email,
    coalesce(sum(t.points), 0)::bigint,
    coalesce(sum(t.points) filter (where t.points > 0), 0)::bigint,
    coalesce(sum(-t.points) filter (where t.points < 0), 0)::bigint,
    max(t.created_at)
  from public.profiles p
  left join public.loyalty_transactions t on t.user_id = p.id
  where not public.is_admin(p.id)
    and (nullif(trim(p_search), '') is null
      or p.full_name ilike '%' || trim(p_search) || '%'
      or p.email ilike '%' || trim(p_search) || '%')
  group by p.id, p.full_name, p.email
  order by coalesce(sum(t.points), 0) desc, p.full_name
  limit p_limit;
end;
$$;

revoke all on function public.loyalty_admin_balances(text, integer) from public, anon;
grant execute on function public.loyalty_admin_balances(text, integer) to authenticated;

create or replace function public.loyalty_admin_ledger(p_user_id uuid, p_limit integer default 100)
returns setof public.loyalty_transactions
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  return query
  select * from public.loyalty_transactions
  where user_id = p_user_id
  order by created_at desc
  limit greatest(1, least(p_limit, 500));
end;
$$;

revoke all on function public.loyalty_admin_ledger(uuid, integer) from public, anon;
grant execute on function public.loyalty_admin_ledger(uuid, integer) to authenticated;

create or replace function public.loyalty_admin_redemptions(p_user_id uuid default null, p_limit integer default 100)
returns setof public.loyalty_redemptions
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  return query
  select * from public.loyalty_redemptions
  where p_user_id is null or user_id = p_user_id
  order by created_at desc
  limit greatest(1, least(p_limit, 500));
end;
$$;

revoke all on function public.loyalty_admin_redemptions(uuid, integer) from public, anon;
grant execute on function public.loyalty_admin_redemptions(uuid, integer) to authenticated;

create or replace function public.feedback_admin_list(
  p_search text default null,
  p_facility_id uuid default null,
  p_min_rating integer default null,
  p_max_rating integer default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_sort text default 'newest',
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
  is_internal boolean := public.is_internal_admin();
  sort_key text := coalesce(p_sort, 'newest');
begin
  if not (is_internal or public.is_external_admin()) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  if sort_key not in ('newest','oldest','highest','lowest') then
    sort_key := 'newest';
  end if;

  with filtered as (
    select f.*, r.facility_name, r.requester_name
    from public.reservation_feedback f
    join public.reservation_requests r on r.id = f.reservation_id
    where (is_internal or public.can_manage_facility(f.facility_id))
      and (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_min_rating is null or f.rating >= p_min_rating)
      and (p_max_rating is null or f.rating <= p_max_rating)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
      and (nullif(trim(p_search), '') is null
        or concat_ws(' ', r.facility_name, r.requester_name, f.comment) ilike '%' || trim(p_search) || '%')
  ), page as (
    select * from filtered
    order by
      case when sort_key = 'newest' then created_at end desc,
      case when sort_key = 'oldest' then created_at end asc,
      case when sort_key = 'highest' then rating end desc,
      case when sort_key = 'lowest' then rating end asc,
      created_at desc
    limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(page)) from page), '[]'::jsonb),
    'total', (select count(*) from filtered)
  ) into result_value;
  return result_value;
end;
$$;

revoke all on function public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text, integer, integer
) from public, anon;
grant execute on function public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text, integer, integer
) to authenticated;

create or replace function public.feedback_admin_summary(
  p_facility_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
  is_internal boolean := public.is_internal_admin();
begin
  if not (is_internal or public.is_external_admin()) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;

  with scoped as (
    select f.* from public.reservation_feedback f
    where (is_internal or public.can_manage_facility(f.facility_id))
      and (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
  ),
  by_facility as (
    select s.facility_id, fac.name as facility_name,
      round(avg(s.rating)::numeric, 2) as average, count(*) as total
    from scoped s
    join public.facilities fac on fac.id = s.facility_id
    group by s.facility_id, fac.name
    having count(*) >= 3
  )
  select jsonb_build_object(
    'average', (select round(avg(rating)::numeric, 2) from scoped),
    'total', (select count(*) from scoped),
    'five_star', (select count(*) from scoped where rating = 5),
    'low_rated', (select count(*) from scoped where rating <= 2),
    'highest', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.average desc)
      from (select * from by_facility order by average desc limit 5) x
    ), '[]'::jsonb),
    'lowest', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.average asc)
      from (select * from by_facility order by average asc limit 5) x
    ), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

revoke all on function public.feedback_admin_summary(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.feedback_admin_summary(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- RLS and grants
-- ---------------------------------------------------------------------

alter table public.reservation_feedback enable row level security;
alter table public.facility_rating_stats enable row level security;
alter table public.loyalty_point_rules enable row level security;
alter table public.loyalty_transactions enable row level security;
alter table public.loyalty_rewards enable row level security;
alter table public.loyalty_redemptions enable row level security;

revoke all on public.reservation_feedback from public, anon, authenticated;
revoke all on public.facility_rating_stats from public, anon, authenticated;
revoke all on public.loyalty_point_rules from public, anon, authenticated;
revoke all on public.loyalty_transactions from public, anon, authenticated;
revoke all on public.loyalty_rewards from public, anon, authenticated;
revoke all on public.loyalty_redemptions from public, anon, authenticated;

-- select only. Every write is a security definer RPC above.
grant select on public.reservation_feedback to authenticated;
grant select on public.facility_rating_stats to authenticated;
grant select on public.loyalty_point_rules to authenticated;
grant select on public.loyalty_transactions to authenticated;
grant select on public.loyalty_rewards to authenticated;
grant select on public.loyalty_redemptions to authenticated;

drop policy if exists reservation_feedback_read on public.reservation_feedback;
create policy reservation_feedback_read
on public.reservation_feedback for select to authenticated
using (
  user_id = auth.uid()
  or public.is_internal_admin()
  or public.can_manage_facility(facility_id)
);

drop policy if exists facility_rating_stats_read on public.facility_rating_stats;
create policy facility_rating_stats_read
on public.facility_rating_stats for select to authenticated
using (true);

drop policy if exists loyalty_point_rules_read on public.loyalty_point_rules;
create policy loyalty_point_rules_read
on public.loyalty_point_rules for select to authenticated
using (true);

drop policy if exists loyalty_transactions_read on public.loyalty_transactions;
create policy loyalty_transactions_read
on public.loyalty_transactions for select to authenticated
using (user_id = auth.uid() or public.is_internal_admin());

drop policy if exists loyalty_rewards_read on public.loyalty_rewards;
create policy loyalty_rewards_read
on public.loyalty_rewards for select to authenticated
using (active or public.is_internal_admin());

drop policy if exists loyalty_redemptions_read on public.loyalty_redemptions;
create policy loyalty_redemptions_read
on public.loyalty_redemptions for select to authenticated
using (user_id = auth.uid() or public.is_internal_admin());

-- ---------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'loyalty_transactions'
  ) then
    alter publication supabase_realtime add table public.loyalty_transactions;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'facility_rating_stats'
  ) then
    alter publication supabase_realtime add table public.facility_rating_stats;
  end if;
end $$;
