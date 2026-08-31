-- External-admin-only loyalty administration.
-- This migration changes authorization surfaces only; existing loyalty data
-- remains intact for audit and historical reporting.

drop function if exists public.adjust_loyalty_points(uuid, integer, text);

create or replace function public.loyalty_balance(p_user_id uuid default auth.uid())
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_user_id <> auth.uid() and not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  if not public.loyalty_user_is_eligible(p_user_id) then
    return 0;
  end if;
  return coalesce(
    (select sum(points) from public.loyalty_transactions where user_id = p_user_id), 0
  );
end;
$$;

create or replace function public.loyalty_admin_balances(
  p_search text default null,
  p_limit integer default 100
) returns table(
  user_id uuid,
  full_name text,
  email text,
  balance numeric,
  lifetime_earned numeric,
  lifetime_redeemed numeric,
  last_activity_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  if p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;

  return query
  select p.id, p.full_name, p.email,
    coalesce(sum(t.points), 0),
    coalesce(sum(t.points) filter (where t.points > 0), 0),
    coalesce(sum(-t.points) filter (where t.points < 0), 0),
    max(t.created_at)
  from public.profiles p
  left join public.loyalty_transactions t on t.user_id = p.id
  where public.loyalty_user_is_eligible(p.id)
    and (
      nullif(trim(p_search), '') is null
      or p.full_name ilike '%' || trim(p_search) || '%'
      or p.email ilike '%' || trim(p_search) || '%'
    )
  group by p.id, p.full_name, p.email
  order by coalesce(sum(t.points), 0) desc, p.full_name
  limit p_limit;
end;
$$;

create or replace function public.loyalty_admin_ledger(
  p_user_id uuid,
  p_limit integer default 100
) returns setof public.loyalty_transactions
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  if not public.loyalty_user_is_eligible(p_user_id) then
    raise exception using errcode = '42501', message = 'Loyalty history is limited to guest renters';
  end if;

  return query
  select * from public.loyalty_transactions
  where user_id = p_user_id
  order by created_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

create or replace function public.loyalty_admin_redemptions(
  p_user_id uuid default null,
  p_limit integer default 100
) returns setof public.loyalty_redemptions
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;

  return query
  select * from public.loyalty_redemptions
  where p_user_id is null or user_id = p_user_id
  order by created_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

create or replace function public.adjust_loyalty_points(
  p_user_id uuid,
  p_points numeric,
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
  balance numeric;
  clean_reason text;
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  if p_points is null or p_points = 0 or p_points * 2 <> trunc(p_points * 2) then
    raise exception using errcode = '22023', message = 'Enter a nonzero half-point amount';
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

  select coalesce(sum(points), 0) into balance
  from public.loyalty_transactions
  where user_id = p_user_id;

  if balance + p_points < 0 then
    raise exception using errcode = '22023', message = 'This adjustment would take the balance below zero';
  end if;

  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description, actor_id
  ) values (
    p_user_id,
    p_points::numeric(10,1),
    'admin_adjustment',
    'admin',
    gen_random_uuid(),
    'Admin adjustment: ' || clean_reason,
    auth.uid()
  ) returning * into ledger;

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, details, material, source_type, source_id
  ) values (
    'account',
    p_user_id,
    coalesce(nullif(target.full_name, ''), target.email),
    auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email),
    actor.role,
    'adjusted loyalty points',
    clean_reason,
    jsonb_build_object('balance', balance),
    jsonb_build_object('balance', balance + p_points),
    jsonb_build_object(
      'target_renter_id', p_user_id,
      'actor_id', auth.uid(),
      'actor_role', actor.role,
      'points', p_points,
      'reason', clean_reason,
      'previous_balance', balance,
      'resulting_balance', balance + p_points,
      'loyalty_transaction_id', ledger.id
    ),
    true,
    'loyalty_adjustment',
    ledger.id
  );

  insert into public.app_notifications(recipient_id, kind, title, body)
  values (
    p_user_id,
    'loyalty_earned',
    (case when p_points > 0 then '+' else '' end) || trim(to_char(p_points, 'FM999999990.0')) || ' points',
    'Admin adjustment: ' || clean_reason
  );

  return ledger;
end;
$$;

create or replace function public.loyalty_admin_claims(
  p_search text default null,
  p_status text default null,
  p_limit integer default 100
) returns table(
  claim_id uuid,
  renter_user_id uuid,
  renter_full_name text,
  renter_email text,
  offer_id uuid,
  offer_name text,
  discount_kind text,
  fixed_amount_centavos integer,
  percentage numeric,
  facility_id uuid,
  facility_name text,
  points_spent numeric,
  expiry_date date,
  status text,
  effective_status text,
  application_id uuid,
  application_status text,
  release_reason text,
  applied_at timestamptz,
  released_at timestamptz,
  application_consumed_at timestamptz,
  reservation_id uuid,
  claimed_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  today date := (now() at time zone 'Asia/Manila')::date;
  clean_search text := nullif(trim(coalesce(p_search, '')), '');
  clean_status text := nullif(trim(coalesce(p_status, '')), '');
  limit_value integer := greatest(1, least(coalesce(p_limit, 100), 500));
begin
  if not public.is_external_admin() then
    raise exception using errcode = '42501', message = 'External administrator access required';
  end if;
  if clean_status is not null and clean_status not in ('claimed', 'applied', 'consumed', 'expired') then
    raise exception using errcode = '22023', message = 'Invalid voucher status';
  end if;

  return query
  select
    c.id,
    c.user_id,
    p.full_name,
    p.email,
    c.offer_id,
    c.offer_name,
    c.discount_kind,
    c.fixed_amount_centavos,
    c.percentage,
    c.facility_id,
    f.name,
    c.points_spent,
    c.expiry_date,
    c.status,
    case
      when c.status <> 'consumed' and c.expiry_date < today then 'expired'
      else c.status
    end,
    a.id,
    a.status,
    a.release_reason,
    a.applied_at,
    a.released_at,
    a.consumed_at,
    a.reservation_id,
    c.claimed_at,
    c.consumed_at,
    c.created_at
  from public.loyalty_discount_claims c
  join public.profiles p on p.id = c.user_id
  left join public.facilities f on f.id = c.facility_id
  left join lateral (
    select *
    from public.loyalty_discount_applications lda
    where lda.claim_id = c.id
    order by lda.applied_at desc, lda.created_at desc
    limit 1
  ) a on true
  where (
      clean_search is null
      or p.full_name ilike '%' || clean_search || '%'
      or p.email ilike '%' || clean_search || '%'
      or c.offer_name ilike '%' || clean_search || '%'
    )
    and (
      clean_status is null
      or clean_status = case
        when c.status <> 'consumed' and c.expiry_date < today then 'expired'
        else c.status
      end
    )
  order by c.created_at desc, c.id desc
  limit limit_value;
end;
$$;

alter table public.loyalty_point_rules enable row level security;
alter table public.loyalty_transactions enable row level security;
alter table public.loyalty_rewards enable row level security;
alter table public.loyalty_redemptions enable row level security;
alter table public.loyalty_discount_offers enable row level security;
alter table public.loyalty_discount_claims enable row level security;
alter table public.loyalty_discount_applications enable row level security;

revoke all on public.loyalty_point_rules from public, anon, authenticated;
revoke all on public.loyalty_transactions from public, anon, authenticated;
revoke all on public.loyalty_rewards from public, anon, authenticated;
revoke all on public.loyalty_redemptions from public, anon, authenticated;
revoke all on public.loyalty_discount_offers from public, anon, authenticated;
revoke all on public.loyalty_discount_claims from public, anon, authenticated;
revoke all on public.loyalty_discount_applications from public, anon, authenticated;

grant select on public.loyalty_point_rules to authenticated;
grant select on public.loyalty_transactions to authenticated;
grant select on public.loyalty_rewards to authenticated;
grant select on public.loyalty_redemptions to authenticated;
grant select on public.loyalty_discount_offers to authenticated;
grant select on public.loyalty_discount_claims to authenticated;
grant select on public.loyalty_discount_applications to authenticated;

drop policy if exists loyalty_point_rules_read on public.loyalty_point_rules;
create policy loyalty_point_rules_read
on public.loyalty_point_rules for select to authenticated
using (true);

drop policy if exists loyalty_transactions_read on public.loyalty_transactions;
create policy loyalty_transactions_read
on public.loyalty_transactions for select to authenticated
using (user_id = auth.uid() or public.is_external_admin());

drop policy if exists loyalty_rewards_read on public.loyalty_rewards;
create policy loyalty_rewards_read
on public.loyalty_rewards for select to authenticated
using (active or public.is_external_admin());

drop policy if exists loyalty_redemptions_read on public.loyalty_redemptions;
create policy loyalty_redemptions_read
on public.loyalty_redemptions for select to authenticated
using (user_id = auth.uid() or public.is_external_admin());

drop policy if exists loyalty_discount_offers_read on public.loyalty_discount_offers;
create policy loyalty_discount_offers_read
on public.loyalty_discount_offers for select to authenticated
using (
  public.is_external_admin()
  or (
    active
    and public.loyalty_user_is_eligible(auth.uid())
    and (now() at time zone 'Asia/Manila')::date between valid_from and valid_until
  )
);

drop policy if exists loyalty_discount_claims_read on public.loyalty_discount_claims;
create policy loyalty_discount_claims_read
on public.loyalty_discount_claims for select to authenticated
using (user_id = auth.uid() or public.is_external_admin());

drop policy if exists loyalty_discount_applications_read on public.loyalty_discount_applications;
create policy loyalty_discount_applications_read
on public.loyalty_discount_applications for select to authenticated
using (
  public.is_external_admin()
  or exists (
    select 1 from public.loyalty_discount_claims c
    where c.id = claim_id and c.user_id = auth.uid()
  )
);

revoke all on function public.loyalty_balance(uuid) from public, anon, authenticated;
revoke all on function public.loyalty_my_summary() from public, anon, authenticated;
revoke all on function public.claim_loyalty_discount(uuid) from public, anon, authenticated;
revoke all on function public.loyalty_admin_balances(text, integer) from public, anon, authenticated;
revoke all on function public.loyalty_admin_ledger(uuid, integer) from public, anon, authenticated;
revoke all on function public.loyalty_admin_redemptions(uuid, integer) from public, anon, authenticated;
revoke all on function public.loyalty_admin_claims(text, text, integer) from public, anon, authenticated;
revoke all on function public.adjust_loyalty_points(uuid, numeric, text) from public, anon, authenticated;
revoke all on function public.loyalty_discount_offer_admin_list() from public, anon, authenticated;
revoke all on function public.save_loyalty_discount_offer(
  uuid, text, text, numeric, text, integer, numeric, uuid, date, date, boolean
) from public, anon, authenticated;
revoke all on function public.set_loyalty_discount_offer_active(uuid, boolean) from public, anon, authenticated;
revoke all on function public.redeem_loyalty_reward(uuid) from public, anon, authenticated;
revoke all on function public.save_loyalty_reward(uuid, text, text, integer, boolean, integer) from public, anon, authenticated;
revoke all on function public.set_loyalty_reward_active(uuid, boolean) from public, anon, authenticated;

grant execute on function public.loyalty_balance(uuid) to authenticated;
grant execute on function public.loyalty_my_summary() to authenticated;
grant execute on function public.claim_loyalty_discount(uuid) to authenticated;
grant execute on function public.loyalty_admin_balances(text, integer) to authenticated;
grant execute on function public.loyalty_admin_ledger(uuid, integer) to authenticated;
grant execute on function public.loyalty_admin_redemptions(uuid, integer) to authenticated;
grant execute on function public.loyalty_admin_claims(text, text, integer) to authenticated;
grant execute on function public.adjust_loyalty_points(uuid, numeric, text) to authenticated;
grant execute on function public.loyalty_discount_offer_admin_list() to authenticated;
grant execute on function public.save_loyalty_discount_offer(
  uuid, text, text, numeric, text, integer, numeric, uuid, date, date, boolean
) to authenticated;
grant execute on function public.set_loyalty_discount_offer_active(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
