-- Fix the loyalty voucher admin RPC return shape. Some source columns, such
-- as facilities.name, are citext; RETURNS TABLE requires exact runtime types.

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
    c.id::uuid,
    c.user_id::uuid,
    p.full_name::text,
    p.email::text,
    c.offer_id::uuid,
    c.offer_name::text,
    c.discount_kind::text,
    c.fixed_amount_centavos::integer,
    c.percentage::numeric,
    c.facility_id::uuid,
    f.name::text,
    c.points_spent::numeric,
    c.expiry_date::date,
    c.status::text,
    (case
      when c.status <> 'consumed' and c.expiry_date < today then 'expired'
      else c.status
    end)::text,
    a.id::uuid,
    a.status::text,
    a.release_reason::text,
    a.applied_at::timestamptz,
    a.released_at::timestamptz,
    a.consumed_at::timestamptz,
    a.reservation_id::uuid,
    c.claimed_at::timestamptz,
    c.consumed_at::timestamptz,
    c.created_at::timestamptz
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
      or clean_status = (case
        when c.status <> 'consumed' and c.expiry_date < today then 'expired'
        else c.status
      end)::text
    )
  order by c.created_at desc, c.id desc
  limit limit_value;
end;
$$;

revoke all on function public.loyalty_admin_claims(text, text, integer)
  from public, anon, authenticated;
grant execute on function public.loyalty_admin_claims(text, text, integer)
  to authenticated;

notify pgrst, 'reload schema';
