-- Restrict loyalty points and rewards to active guest-priced renters.
-- Existing ledger rows remain intact for audit, but ineligible users cannot
-- view or spend their balances while they are no longer guest-priced.

create or replace function public.loyalty_user_is_eligible(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.role = 'user'
      and p.account_status = 'active'
      and public.requester_pricing_audience(p_user_id) = 'guest'
  );
$$;

revoke all on function public.loyalty_user_is_eligible(uuid) from public, anon;
grant execute on function public.loyalty_user_is_eligible(uuid) to authenticated;

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
     and new.pricing_audience = 'guest'
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
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
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

  if request_row.pricing_audience = 'guest' then
    award_points := public.loyalty_points_for('feedback_submitted');
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description
    ) values (
      auth.uid(), award_points, 'feedback_submitted', 'feedback',
      result.id, 'Feedback for ' || request_row.facility_name
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
    returning id into awarded_id;

    if awarded_id is not null then
      insert into public.app_notifications(recipient_id, request_id, kind, title, body)
      values (
        auth.uid(), p_reservation_id, 'loyalty_earned',
        '+' || award_points || ' points',
        'Thanks for rating ' || request_row.facility_name || '.'
      );
    end if;
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
  if not public.loyalty_user_is_eligible(p_user_id) then
    return 0;
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

  if not public.loyalty_user_is_eligible(auth.uid()) then
    raise exception using errcode = '42501', message = 'Loyalty rewards are available to guest renters only';
  end if;

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
  if not public.loyalty_user_is_eligible(p_user_id) then
    raise exception using errcode = '42501', message = 'Loyalty adjustments are limited to guest renters';
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

create or replace function public.loyalty_my_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  eligible boolean;
  result_value jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  eligible := public.loyalty_user_is_eligible(auth.uid());
  if not eligible then
    return jsonb_build_object(
      'eligible', false,
      'balance', 0,
      'lifetime_earned', 0,
      'lifetime_redeemed', 0,
      'rules', '{}'::jsonb,
      'transactions', '[]'::jsonb,
      'redemptions', '[]'::jsonb,
      'rewards', '[]'::jsonb
    );
  end if;

  select jsonb_build_object(
    'eligible', true,
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
  where public.loyalty_user_is_eligible(p.id)
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

drop policy if exists loyalty_transactions_read on public.loyalty_transactions;
create policy loyalty_transactions_read
on public.loyalty_transactions for select to authenticated
using (
  (user_id = auth.uid() and public.loyalty_user_is_eligible(auth.uid()))
  or public.is_internal_admin()
);

drop policy if exists loyalty_rewards_read on public.loyalty_rewards;
create policy loyalty_rewards_read
on public.loyalty_rewards for select to authenticated
using (
  (active and public.loyalty_user_is_eligible(auth.uid()))
  or public.is_internal_admin()
);

drop policy if exists loyalty_redemptions_read on public.loyalty_redemptions;
create policy loyalty_redemptions_read
on public.loyalty_redemptions for select to authenticated
using (
  (user_id = auth.uid() and public.loyalty_user_is_eligible(auth.uid()))
  or public.is_internal_admin()
);
