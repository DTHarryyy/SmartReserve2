-- Payment reminders ahead of the deposit and balance deadlines, reusing the
-- existing app_notifications channel. Also fixes expire_due_reservations,
-- which updated the reservation and released the slot but never told the
-- renter why their reservation disappeared.

create table if not exists public.reservation_payment_reminders (
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  kind text not null check (kind in (
    'down_payment_t6','balance_t48','balance_t24','balance_t6'
  )),
  sent_at timestamptz not null default now(),
  primary key (request_id, kind)
);

alter table public.reservation_payment_reminders enable row level security;
grant select on public.reservation_payment_reminders to authenticated;
create policy reservation_payment_reminders_read
on public.reservation_payment_reminders for select to authenticated
using (public.can_access_reservation(request_id));

-- The reason a reservation expired matters to the renter (missed deposit vs.
-- missed balance) more than it matters to the slot being freed, so this is
-- the same wording expire_due_reservations already records as the event
-- reason -- it was simply never relayed as a notification.
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
  event_id uuid;
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

      event_id := public.reservation_event(
        candidate.id,
        'expired automatically',
        candidate.reason_value,
        '{}'::jsonb,
        null,
        true
      );
      perform public.notify_reservation_user(
        candidate.id, event_id, 'reservation_expired', 'Reservation expired',
        candidate.reason_value || '. The facility and time slot are available again.'
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

-- Sends at most one notification per (reservation, tier), gated by the
-- primary key above. Safe to run as often as the cron schedule likes.
create or replace function public.send_payment_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate record;
  sent_count integer := 0;
begin
  for candidate in
    select r.id as request_id, 'down_payment_t6' as kind,
      'Down payment reminder' as title,
      'Your GCash down payment proof is due within 6 hours, or the hold on '
        || r.facility_name || ' will be released.' as body
    from public.reservation_requests r
    where not r.legacy_financial_state
      and r.reservation_status = 'awaiting_payment'
      and r.payment_due_at is not null
      and r.payment_due_at between now() and now() + interval '6 hours'
      and not exists (
        select 1 from public.payment_transactions p
        where p.request_id = r.id and p.status = 'submitted'
      )
      and not exists (
        select 1 from public.reservation_payment_reminders rr
        where rr.request_id = r.id and rr.kind = 'down_payment_t6'
      )

    union all

    select r.id, tier.kind,
      'Remaining balance reminder',
      'Pay the remaining balance for ' || r.facility_name || ' by '
        || to_char(r.balance_due_at at time zone 'Asia/Manila', 'FMMonth FMDD, YYYY "at" FMHH12:MI AM')
        || ' (PHT) or the reservation will be cancelled and the slot released.'
    from public.reservation_requests r
    cross join lateral (
      values
        ('balance_t48', interval '48 hours'),
        ('balance_t24', interval '24 hours'),
        ('balance_t6', interval '6 hours')
    ) as tier(kind, lead)
    where not r.legacy_financial_state
      and r.reservation_status = 'confirmed'
      and r.total_amount_centavos > 0
      and r.balance_due_at is not null
      and r.balance_due_at between now() and now() + tier.lead
      and (
        select coalesce(sum(p.amount_centavos), 0) from public.payment_transactions p
        where p.request_id = r.id and p.status = 'verified'
      ) < r.total_amount_centavos
      and not exists (
        select 1 from public.reservation_payment_reminders rr
        where rr.request_id = r.id and rr.kind = tier.kind
      )
  loop
    insert into public.reservation_payment_reminders(request_id, kind)
    values (candidate.request_id, candidate.kind)
    on conflict (request_id, kind) do nothing;
    if found then
      perform public.notify_reservation_user(
        candidate.request_id, null, 'payment_reminder', candidate.title, candidate.body
      );
      sent_count := sent_count + 1;
    end if;
  end loop;
  return sent_count;
end;
$$;

revoke all on function public.send_payment_reminders() from public, anon, authenticated;
grant execute on function public.send_payment_reminders() to service_role;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'smartreserve-payment-reminders') then
    perform cron.schedule(
      'smartreserve-payment-reminders', '*/15 * * * *',
      'select public.send_payment_reminders();'
    );
  end if;
end $$;

notify pgrst, 'reload schema';
