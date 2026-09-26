-- Qualify reservation-expiry updates so PL/pgSQL output columns cannot shadow
-- table columns when the scheduled job runs.
create or replace function public.expire_due_reservations(
  p_dry_run boolean default false
)
returns table(request_id uuid, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate record;
begin
  for candidate in
    select
      request.id,
      case
        when request.reservation_status = 'awaiting_payment'
          then 'Down payment deadline missed'
        else 'Remaining balance deadline missed'
      end as reason_value
    from public.reservation_requests as request
    where not request.legacy_financial_state
      and (
        (
          request.reservation_status = 'awaiting_payment'
          and request.payment_due_at < now()
          and not exists (
            select 1
            from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'submitted'
          )
        )
        or (
          request.reservation_status = 'confirmed'
          and request.total_amount_centavos > 0
          and request.balance_due_at < now()
          and not exists (
            select 1
            from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'submitted'
          )
          and (
            select coalesce(sum(payment.amount_centavos), 0)
            from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'verified'
          ) < request.total_amount_centavos
        )
      )
    order by request.id
    for update
  loop
    request_id := candidate.id;
    reason := candidate.reason_value;

    if not p_dry_run then
      update public.reservation_occurrences as occurrence
      set booking_state = 'expired',
          exception_reason = candidate.reason_value
      where occurrence.request_id = candidate.id
        and occurrence.booking_state in ('held', 'booked');

      update public.reservation_requests as request
      set reservation_status = 'expired',
          status = 'expired',
          decision_reason = candidate.reason_value,
          decided_at = now()
      where request.id = candidate.id;

      perform public.reservation_event(
        candidate.id,
        'expired automatically',
        candidate.reason_value,
        '{}'::jsonb,
        null,
        true
      );
    end if;

    return next;
  end loop;
end;
$$;

revoke all on function public.expire_due_reservations(boolean)
  from public, anon, authenticated;
grant execute on function public.expire_due_reservations(boolean)
  to service_role;

notify pgrst, 'reload schema';
