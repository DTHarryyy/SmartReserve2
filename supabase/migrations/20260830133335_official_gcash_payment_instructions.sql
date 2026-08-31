-- Make the official GCash destination the default for paid reservation
-- approvals, and send renters the payment instructions immediately after
-- approval puts the booking on hold.

do $$
declare
  official_account_name constant text := 'Janna Grace Somera';
  official_account_number constant text := '09123456789';
  official_instructions constant text :=
    'Send GCash payment to Janna Grace Somera - 09123456789. Submit the reference number and proof in SmartReserve after approval.';
begin
  -- If the current active official account is not yet attached to a
  -- reservation, normalize its instructions in place.
  update public.facility_payment_methods as method
  set instructions = official_instructions,
      updated_at = now(),
      updated_by = auth.uid()
  where method.method_type = 'gcash'
    and method.enabled
    and method.account_name = official_account_name
    and method.account_number = official_account_number
    and method.instructions is distinct from official_instructions
    and not exists (
      select 1
      from public.reservation_requests as request
      where request.payment_method_id = method.id
    );

  -- Preserve old rows for historic reservations, but ensure future approvals
  -- cannot use a placeholder, incorrect number, or stale instruction body.
  update public.facility_payment_methods as method
  set enabled = false,
      updated_at = now(),
      updated_by = auth.uid()
  where method.method_type = 'gcash'
    and method.enabled
    and (
      method.account_name is distinct from official_account_name
      or method.account_number is distinct from official_account_number
      or method.instructions is distinct from official_instructions
    );

  insert into public.facility_payment_methods (
    facility_id, method_type, account_name, account_number, instructions
  )
  select
    facility.id,
    'gcash',
    official_account_name,
    official_account_number,
    official_instructions
  from public.facilities as facility
  where not exists (
    select 1
    from public.facility_payment_methods as method
    where method.facility_id = facility.id
      and method.method_type = 'gcash'
      and method.enabled
  );
end;
$$;

create or replace function public.seed_default_gcash_payment_method()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.facility_payment_methods (
    facility_id, method_type, account_name, account_number, instructions
  ) values (
    new.id,
    'gcash',
    'Janna Grace Somera',
    '09123456789',
    'Send GCash payment to Janna Grace Somera - 09123456789. Submit the reference number and proof in SmartReserve after approval.'
  )
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists facilities_seed_default_gcash on public.facilities;
create trigger facilities_seed_default_gcash
after insert on public.facilities
for each row execute function public.seed_default_gcash_payment_method();

revoke all on function public.seed_default_gcash_payment_method()
  from public, anon, authenticated;

create or replace function public.apply_reservation_payment_gate(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  facility public.facilities%rowtype;
  payment_method public.facility_payment_methods%rowtype;
  first_start timestamptz;
  payment_due timestamptz;
  balance_due timestamptz;
  event_id uuid;
  notification_body text;
begin
  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;

  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;

  if not public.lock_reservation_admin_scope(p_request_id)
      and request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  if request_row.reservation_status = 'awaiting_payment'
      and request_row.payment_method_id is not null then
    return;
  end if;

  select * into facility
  from public.facilities
  where id = request_row.facility_id;

  select min(starts_at) into first_start
  from public.reservation_occurrences
  where request_id = p_request_id
    and booking_state = 'booked';

  if request_row.total_amount_centavos = 0 then
    update public.reservation_requests
    set reservation_status = 'confirmed',
        payment_method_id = null,
        payment_due_at = null,
        balance_due_at = null
    where id = p_request_id;

    perform public.issue_reservation_permit(p_request_id);
    return;
  end if;

  select * into payment_method
  from public.facility_payment_methods
  where facility_id = request_row.facility_id
    and enabled
    and method_type = 'gcash'
  order by updated_at desc
  limit 1;

  if payment_method.id is null then
    raise exception using errcode = '22023',
      message = 'Configure an active GCash payment method before approving paid reservations';
  end if;

  payment_due := now() + make_interval(mins => facility.deposit_window_minutes);
  balance_due := first_start - make_interval(mins => facility.balance_due_lead_minutes);
  notification_body :=
    'Send payment to ' || payment_method.account_name || ' — ' ||
    payment_method.account_number ||
    '. Required down payment: PHP ' ||
    trim(to_char(
      request_row.required_down_payment_centavos::numeric / 100,
      'FM999999999990.00'
    )) ||
    '. Due: ' ||
    to_char(payment_due at time zone 'Asia/Manila', 'Mon DD, YYYY HH24:MI') ||
    ' PHT. Submit the GCash reference number and proof in SmartReserve. ' ||
    'Your booking is confirmed only after payment proof is verified.';

  update public.reservation_occurrences
  set booking_state = 'held'
  where request_id = p_request_id
    and booking_state = 'booked';

  update public.reservation_requests
  set reservation_status = 'awaiting_payment',
      payment_method_id = payment_method.id,
      payment_due_at = payment_due,
      balance_due_at = balance_due
  where id = p_request_id;

  event_id := public.reservation_event(
    p_request_id,
    'sent payment instructions',
    null,
    jsonb_build_object(
      'payment_method_id', payment_method.id,
      'account_name', payment_method.account_name,
      'account_number', payment_method.account_number,
      'required_down_payment_centavos', request_row.required_down_payment_centavos,
      'payment_due_at', payment_due
    ),
    null,
    true
  );

  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_payment_instructions',
    'Reservation approved — payment required',
    notification_body
  );
end;
$$;

revoke all on function public.apply_reservation_payment_gate(uuid)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
