-- External admins need a global, sanitized client directory, while
-- reservation/payment operations remain scoped by the existing RLS and action
-- RPC checks.

create or replace function public.get_external_clients()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare result_value jsonb;
begin
  if public.admin_lane() is distinct from 'external' then
    raise exception using errcode = '42501',
      message = 'External administrator access required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', client.id,
    'email', client.email,
    'full_name', coalesce(nullif(client.full_name, ''), client.email),
    'role', 'user',
    'account_status', client.account_status,
    'created_at', client.created_at,
    'reservation_count', client.reservation_count,
    'last_reservation_at', client.last_reservation_at,
    'payment_count', client.payment_count,
    'last_payment_at', client.last_payment_at
  ) order by client.last_activity_at desc, client.created_at desc), '[]'::jsonb)
  into result_value
  from (
    select
      p.id,
      p.email,
      p.full_name,
      p.account_status,
      p.created_at,
      coalesce(reservations.reservation_count, 0)::integer
        as reservation_count,
      reservations.last_reservation_at,
      coalesce(payments.payment_count, 0)::integer as payment_count,
      payments.last_payment_at,
      greatest(
        coalesce(reservations.last_reservation_at, '-infinity'::timestamptz),
        coalesce(payments.last_payment_at, '-infinity'::timestamptz)
      ) as last_activity_at
    from public.profiles p
    left join lateral (
      select count(*)::integer as reservation_count,
        max(r.created_at) as last_reservation_at
      from public.reservation_requests r
      where r.requester_id = p.id
    ) reservations on true
    left join lateral (
      select count(*)::integer as payment_count,
        max(t.submitted_at) as last_payment_at
      from public.payment_transactions t
      where t.payer_id = p.id
    ) payments on true
    where p.role = 'user'
      and p.account_status = 'active'
      and coalesce(p.verification_status, 'none') <> 'verified'
      and (
        coalesce(reservations.reservation_count, 0) > 0
        or coalesce(payments.payment_count, 0) > 0
      )
  ) client;

  return result_value;
end;
$$;

revoke all on function public.get_external_clients() from public, anon;
grant execute on function public.get_external_clients() to authenticated;

notify pgrst, 'reload schema';
