-- Walk-in (campus cashier) payment method.
--
-- Renters could only ever pay through the facility's GCash destination. This
-- adds a second, system-managed method per facility: pay in cash at the school
-- cashier, then upload the registrar/cashier receipt as proof. The proof flow
-- is unchanged -- same payment_transactions row, same admin verification, same
-- correction window -- only the destination and the reference-number semantics
-- differ (a receipt / OR number instead of a GCash reference).

-- ---------------------------------------------------------------------
-- 1. Allow the new method type
-- ---------------------------------------------------------------------

alter table public.facility_payment_methods
  drop constraint if exists facility_payment_methods_method_type_check;
alter table public.facility_payment_methods
  add constraint facility_payment_methods_method_type_check
  check (method_type in ('gcash', 'walk_in'));

-- A walk-in destination is a cashier window, not a mobile number, so the
-- 10-15 digit rule only applies to the wallet-backed methods.
alter table public.facility_payment_methods
  drop constraint if exists facility_payment_methods_account_number_check;
alter table public.facility_payment_methods
  add constraint facility_payment_methods_account_number_check
  check (
    case
      when method_type = 'walk_in'
        then length(trim(account_number)) between 2 and 120
      else length(regexp_replace(account_number, '[^0-9]', '', 'g')) between 10 and 15
    end
  );

-- Cashier receipt (OR) numbers are shorter than GCash references. The table
-- keeps a floor; the per-method minimum (6 for GCash, 3 for walk-in) is
-- enforced by assert_payment_reference() below.
do $$
declare
  stale record;
begin
  for stale in
    select conname
    from pg_constraint
    where conrelid = 'public.payment_transactions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%reference_number%'
  loop
    execute format(
      'alter table public.payment_transactions drop constraint %I', stale.conname
    );
  end loop;
end;
$$;
alter table public.payment_transactions
  add constraint payment_transactions_reference_number_check
  check (length(trim(reference_number)) between 3 and 80);

-- ---------------------------------------------------------------------
-- 2. Renters must be able to read the walk-in row for a facility they
--    already hold a reservation on, even when it is not publicly listed.
-- ---------------------------------------------------------------------

drop policy if exists facility_payment_methods_requester_facility_read
  on public.facility_payment_methods;
create policy facility_payment_methods_requester_facility_read
on public.facility_payment_methods for select to authenticated
using (
  enabled and exists (
    select 1
    from public.reservation_requests as request
    where request.facility_id = facility_payment_methods.facility_id
      and (request.requester_id = auth.uid() or public.can_manage_reservation(request.id))
  )
);

-- ---------------------------------------------------------------------
-- 3. Seed the walk-in destination for every facility, now and on insert
-- ---------------------------------------------------------------------

insert into public.facility_payment_methods (
  facility_id, method_type, account_name, account_number, instructions
)
select
  facility.id,
  'walk_in',
  'CSU Aparri Cashier',
  'Cashier window, Administration building',
  'Pay in cash at the campus cashier during office hours, then upload the registrar or cashier receipt here together with the receipt (OR) number. Your booking is confirmed only after an administrator verifies the receipt.'
from public.facilities as facility
where not exists (
  select 1
  from public.facility_payment_methods as method
  where method.facility_id = facility.id
    and method.method_type = 'walk_in'
    and method.enabled
);

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

  insert into public.facility_payment_methods (
    facility_id, method_type, account_name, account_number, instructions
  ) values (
    new.id,
    'walk_in',
    'CSU Aparri Cashier',
    'Cashier window, Administration building',
    'Pay in cash at the campus cashier during office hours, then upload the registrar or cashier receipt here together with the receipt (OR) number. Your booking is confirmed only after an administrator verifies the receipt.'
  )
  on conflict do nothing;

  return new;
end;
$$;

revoke all on function public.seed_default_gcash_payment_method()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Shared helper: the reference-number rule per method type
-- ---------------------------------------------------------------------

create or replace function public.assert_payment_reference(
  p_method_type text,
  p_reference_number text
) returns void
language plpgsql
set search_path = public
as $$
declare
  trimmed text := trim(coalesce(p_reference_number, ''));
begin
  if p_method_type = 'walk_in' then
    if length(trimmed) < 3 then
      raise exception using errcode = '22023',
        message = 'Provide the registrar or cashier receipt (OR) number';
    end if;
  elsif length(trimmed) < 6 then
    raise exception using errcode = '22023',
      message = 'Provide the GCash reference number';
  end if;
end;
$$;

revoke all on function public.assert_payment_reference(text, text) from public, anon;
grant execute on function public.assert_payment_reference(text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Approval gate: prefer GCash as the reservation default, but do not
--    block approval when only a walk-in destination is published.
-- ---------------------------------------------------------------------

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
  walk_in_method public.facility_payment_methods%rowtype;
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

  select * into walk_in_method
  from public.facility_payment_methods
  where facility_id = request_row.facility_id
    and enabled
    and method_type = 'walk_in'
  order by updated_at desc
  limit 1;

  if payment_method.id is null then
    payment_method := walk_in_method;
  end if;

  if payment_method.id is null then
    raise exception using errcode = '22023',
      message = 'Configure an active payment method before approving paid reservations';
  end if;

  payment_due := now() + make_interval(mins => facility.deposit_window_minutes);
  balance_due := first_start - make_interval(mins => facility.balance_due_lead_minutes);
  notification_body :=
    case payment_method.method_type
      when 'walk_in' then
        'Pay in cash at ' || payment_method.account_name || ' - ' ||
        payment_method.account_number || '.'
      else
        'Send payment to ' || payment_method.account_name || ' - ' ||
        payment_method.account_number || '.'
    end ||
    ' Required down payment: PHP ' ||
    trim(to_char(
      request_row.required_down_payment_centavos::numeric / 100,
      'FM999999999990.00'
    )) ||
    '. Due: ' ||
    to_char(payment_due at time zone 'Asia/Manila', 'Mon DD, YYYY HH24:MI') ||
    ' PHT. ' ||
    case
      when payment_method.method_type = 'walk_in' then
        'Submit the receipt (OR) number and a photo of the receipt in SmartReserve. '
      when walk_in_method.id is not null then
        'Submit the GCash reference number and proof in SmartReserve, or pay in cash at '
          || walk_in_method.account_name || ' and upload the receipt instead. '
      else
        'Submit the GCash reference number and proof in SmartReserve. '
    end ||
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
      'method_type', payment_method.method_type,
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
    'Reservation approved - payment required',
    notification_body
  );
end;
$$;

revoke all on function public.apply_reservation_payment_gate(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. submit_payment / correct_payment_submission accept the method the
--    renter actually used, so the same reservation can be paid by GCash
--    for the down payment and at the cashier for the balance.
-- ---------------------------------------------------------------------

drop function if exists public.submit_payment(uuid, uuid, text, integer, text, text, uuid);

create or replace function public.submit_payment(
  p_transaction_id uuid,
  p_request_id uuid,
  p_purpose text,
  p_amount_centavos integer,
  p_reference_number text,
  p_proof_path text,
  p_idempotency_key uuid,
  p_payment_method_id uuid default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  request_row public.reservation_requests%rowtype;
  method_row public.facility_payment_methods%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'This reservation is not accepting payments';
  end if;
  if p_purpose not in ('down_payment', 'balance') or p_amount_centavos <= 0 then
    raise exception using errcode = '22023', message = 'Provide a valid payment amount and purpose';
  end if;
  if p_payment_method_id is not null then
    select * into method_row
    from public.facility_payment_methods
    where id = p_payment_method_id
      and facility_id = request_row.facility_id
      and enabled;
    if method_row.id is null then
      raise exception using errcode = '22023',
        message = 'Choose a payment method published for this facility';
    end if;
  else
    if request_row.payment_method_id is null then
      raise exception using errcode = '22023', message = 'No payment method is configured for this reservation';
    end if;
    select * into method_row
    from public.facility_payment_methods
    where id = request_row.payment_method_id;
  end if;
  perform public.assert_payment_reference(method_row.method_type, p_reference_number);
  if p_proof_path not like auth.uid()::text || '/' || p_request_id::text || '/%' then
    raise exception using errcode = '42501', message = 'Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = p_request_id
    and status in ('submitted', 'needs_correction', 'verified');
  if p_amount_centavos > request_row.total_amount_centavos - committed_value then
    raise exception using errcode = '22023', message = 'Payment is greater than the outstanding balance';
  end if;
  if request_row.payment_method_id is null then
    update public.reservation_requests set payment_method_id = method_row.id where id = p_request_id;
  end if;
  insert into public.payment_transactions(
    id, request_id, payer_id, payment_method_id, purpose, amount_centavos,
    reference_number, proof_path, idempotency_key
  ) values (
    p_transaction_id, p_request_id, auth.uid(), method_row.id,
    p_purpose, p_amount_centavos, trim(p_reference_number), p_proof_path,
    p_idempotency_key
  )
  returning * into result;
  event_id := public.reservation_event(
    p_request_id,
    'submitted payment proof',
    null,
    jsonb_build_object(
      'payment_id', result.id,
      'purpose', result.purpose,
      'method_type', method_row.method_type,
      'amount_centavos', result.amount_centavos
    ),
    null,
    true
  );
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, p_request_id, event_id, 'payment_submitted',
    'Payment submitted for review',
    request_row.requester_name ||
    case method_row.method_type
      when 'walk_in' then ' submitted a cashier receipt for review.'
      else ' submitted GCash payment proof.'
    end
  from public.profiles p
  where p.account_status = 'active'
    and p.role = case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  on conflict do nothing;
  return result;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'That payment reference or submission was already used';
end;
$$;

drop function if exists public.correct_payment_submission(uuid, integer, text, text, uuid);

create or replace function public.correct_payment_submission(
  p_payment_id uuid,
  p_amount_centavos integer,
  p_reference_number text,
  p_proof_path text,
  p_idempotency_key uuid,
  p_payment_method_id uuid default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  payment_row public.payment_transactions%rowtype;
  request_row public.reservation_requests%rowtype;
  method_row public.facility_payment_methods%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into result
  from public.payment_transactions
  where payer_id = auth.uid()
    and idempotency_key = p_idempotency_key;
  if result.id is not null then
    return result;
  end if;
  select * into payment_row from public.payment_transactions where id = p_payment_id for update;
  if payment_row.id is null then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;
  select * into request_row from public.reservation_requests where id = payment_row.request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() or payment_row.payer_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if payment_row.status <> 'needs_correction' then
    raise exception using errcode = '22023', message = 'This payment is not awaiting correction';
  end if;
  if payment_row.correction_due_at is null or payment_row.correction_due_at < now() then
    raise exception using errcode = '22023', message = 'The payment correction window has ended';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'This reservation is no longer accepting payment corrections';
  end if;
  if p_amount_centavos <= 0 then
    raise exception using errcode = '22023', message = 'Provide a valid payment amount';
  end if;
  select * into method_row
  from public.facility_payment_methods
  where id = coalesce(p_payment_method_id, payment_row.payment_method_id)
    and facility_id = request_row.facility_id
    and (enabled or id = payment_row.payment_method_id);
  if method_row.id is null then
    raise exception using errcode = '22023',
      message = 'Choose a payment method published for this facility';
  end if;
  perform public.assert_payment_reference(method_row.method_type, p_reference_number);
  if p_proof_path not like auth.uid()::text || '/' || request_row.id::text || '/%' then
    raise exception using errcode = '42501', message = 'Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = request_row.id
    and id <> payment_row.id
    and status in ('submitted', 'needs_correction', 'verified');
  if p_amount_centavos > request_row.total_amount_centavos - committed_value then
    raise exception using errcode = '22023', message = 'Payment is greater than the outstanding balance';
  end if;
  update public.payment_transactions
  set amount_centavos = p_amount_centavos,
      payment_method_id = method_row.id,
      reference_number = trim(p_reference_number),
      proof_path = p_proof_path,
      status = 'submitted',
      verified_by = null,
      verified_at = null,
      rejection_reason = null,
      correction_due_at = null,
      correction_count = correction_count + 1,
      last_corrected_at = now(),
      idempotency_key = p_idempotency_key
  where id = p_payment_id
  returning * into result;
  event_id := public.reservation_event(
    request_row.id,
    'corrected payment proof',
    null,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'previous_amount_centavos', payment_row.amount_centavos,
      'previous_reference_number', payment_row.reference_number,
      'previous_proof_path', payment_row.proof_path,
      'method_type', method_row.method_type,
      'amount_centavos', result.amount_centavos
    ),
    null,
    true
  );
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, request_row.id, event_id, 'payment_corrected',
    'Corrected payment submitted for review',
    request_row.requester_name ||
    case method_row.method_type
      when 'walk_in' then ' corrected a cashier receipt.'
      else ' corrected GCash payment proof.'
    end
  from public.profiles p
  where p.account_status = 'active'
    and p.role = case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  on conflict do nothing;
  return result;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'That payment reference or submission was already used';
end;
$$;

revoke all on function public.submit_payment(uuid, uuid, text, integer, text, text, uuid, uuid)
  from public, anon;
revoke all on function public.correct_payment_submission(uuid, integer, text, text, uuid, uuid)
  from public, anon;
grant execute on function public.submit_payment(uuid, uuid, text, integer, text, text, uuid, uuid)
  to authenticated;
grant execute on function public.correct_payment_submission(uuid, integer, text, text, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- 7. Assistant knowledge: walk-in is now an answer to "how do I pay?"
-- ---------------------------------------------------------------------

update public.assistant_knowledge_base
set answer = 'You can pay through the facility''s GCash destination, or pay in cash at the campus cashier (walk-in). Either way, submit the reference number - the GCash reference or the cashier/registrar receipt (OR) number - and a photo of your proof on the reservation. An administrator verifies it. Until it is verified the amount still shows as outstanding.',
    version = version + 1,
    keywords = array[
      'how to pay', 'paano magbayad', 'gcash', 'proof', 'reference number',
      'walk in', 'walk-in', 'cashier', 'cash', 'registrar', 'receipt', 'or number'
    ]
where slug = 'payment.how_to_pay';

notify pgrst, 'reload schema';
