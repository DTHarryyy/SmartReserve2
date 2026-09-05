alter table public.reservation_occurrences
  add column if not exists attendance_marked_at timestamptz,
  add column if not exists attendance_marked_by uuid references public.profiles(id) on delete set null,
  add column if not exists attendance_reason text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete set null,
  add column if not exists cancellation_reason text;

alter table public.reservation_requests
  add column if not exists terminal_at timestamptz,
  add column if not exists terminal_reason_code text;

alter table public.reservation_requests
  drop constraint if exists reservation_requests_terminal_reason_code_check,
  add constraint reservation_requests_terminal_reason_code_check
    check (
      terminal_reason_code is null
      or terminal_reason_code in (
        'stale_pending',
        'manual_expiration',
        'down_payment_deadline',
        'balance_payment_deadline'
      )
    );

create index if not exists reservation_requests_requester_lane_created_idx
  on public.reservation_requests(requester_id, admin_lane, created_at desc);

create index if not exists reservation_requests_terminal_reason_idx
  on public.reservation_requests(requester_id, terminal_reason_code, terminal_at desc)
  where terminal_reason_code is not null;

create index if not exists reservation_occurrences_lifecycle_start_idx
  on public.reservation_occurrences(lifecycle_stage, starts_at desc, request_id)
  where lifecycle_stage in ('checked_in', 'completed', 'no_show');

create index if not exists reservation_occurrences_cancelled_idx
  on public.reservation_occurrences(cancelled_at desc, request_id)
  where cancelled_at is not null;

update public.reservation_occurrences o
set attendance_marked_at = e.created_at,
    attendance_marked_by = e.actor_id,
    attendance_reason = e.reason
from (
  select occ.id as occurrence_id, ev.created_at, ev.actor_id, ev.reason
  from public.reservation_occurrences occ
  cross join lateral (
    select ev2.created_at, ev2.actor_id, ev2.reason
    from public.reservation_events ev2
    where ev2.request_id = occ.request_id
      and ev2.occurrence_id = occ.id
      and ev2.action in ('complete', 'no show')
    order by ev2.created_at desc
    limit 1
  ) ev
  where occ.lifecycle_stage in ('completed', 'no_show')
    and occ.attendance_marked_at is null
) e
where e.occurrence_id = o.id;

update public.reservation_occurrences o
set cancelled_at = e.created_at,
    cancelled_by = e.actor_id,
    cancellation_reason = coalesce(e.reason, o.exception_reason)
from (
  select occ.id as occurrence_id, ev.created_at, ev.actor_id, ev.reason
  from public.reservation_occurrences occ
  cross join lateral (
    select ev2.created_at, ev2.actor_id, ev2.reason
    from public.reservation_events ev2
    where ev2.request_id = occ.request_id
      and ev2.action = 'cancel'
      and (ev2.occurrence_id = occ.id or ev2.occurrence_id is null)
    order by ev2.created_at desc
    limit 1
  ) ev
  where occ.booking_state = 'cancelled'
    and occ.cancelled_at is null
) e
where e.occurrence_id = o.id;

update public.reservation_requests
set terminal_at = coalesce(decided_at, updated_at),
    terminal_reason_code = case decision_reason
      when 'Down payment deadline missed' then 'down_payment_deadline'
      when 'Remaining balance deadline missed' then 'balance_payment_deadline'
      else terminal_reason_code
    end
where reservation_status = 'expired'
  and terminal_at is null
  and decision_reason in ('Down payment deadline missed', 'Remaining balance deadline missed');

create or replace function public.record_occurrence_attendance(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_action text,
  p_reason text default null,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  event_id uuid;
  target_stage text;
  now_version integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_action not in ('check_in', 'complete', 'no_show') then
    raise exception using errcode = '22023', message = 'Unknown attendance action';
  end if;
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> p_action or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023',
        message = 'That attendance key was already used for another action';
    end if;
    return jsonb_build_object('duplicate', true, 'action_id', null, 'undo_until', null);
  end if;

  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed reservation can enter facility use';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;

  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null or occurrence_row.booking_state <> 'booked' then
    raise exception using errcode = '22023', message = 'This occurrence is not booked';
  end if;
  if p_action = 'check_in' and now() < occurrence_row.starts_at - interval '30 minutes' then
    raise exception using errcode = '22023', message = 'Check-in opens 30 minutes before the booking';
  end if;
  if p_action = 'complete' and occurrence_row.lifecycle_stage <> 'checked_in' then
    raise exception using errcode = '22023', message = 'Check in before completing this booking';
  end if;
  if p_action = 'no_show' and now() < occurrence_row.starts_at + interval '15 minutes' then
    raise exception using errcode = '22023', message = 'The no-show grace period has not ended';
  end if;

  target_stage := case p_action
    when 'check_in' then 'checked_in'
    when 'complete' then 'completed'
    else 'no_show'
  end;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, p_action, array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row));

  update public.reservation_occurrences
  set lifecycle_stage = target_stage,
      attendance_marked_at = case when target_stage in ('completed', 'no_show') then now() else attendance_marked_at end,
      attendance_marked_by = case when target_stage in ('completed', 'no_show') then auth.uid() else attendance_marked_by end,
      attendance_reason = case when target_stage in ('completed', 'no_show') then nullif(trim(p_reason), '') else attendance_reason end
  where id = occurrence_row.id;

  if p_action = 'check_in' then
    update public.reservation_requests
    set payment_status = case when payment_status = 'authorized' then 'captured' else payment_status end
    where id = p_request_id;
  elsif not exists (
    select 1 from public.reservation_occurrences
    where request_id = p_request_id
      and lifecycle_stage not in ('completed', 'no_show')
  ) then
    update public.reservation_requests
    set reservation_status = 'completed'
    where id = p_request_id;
  end if;

  event_id := public.reservation_event(
    p_request_id,
    replace(p_action, '_', ' '),
    p_reason,
    jsonb_build_object('occurrence_id', occurrence_row.id),
    occurrence_row.id,
    p_action <> 'check_in'
  );

  if p_action <> 'check_in' then
    perform public.notify_reservation_user(
      p_request_id,
      event_id,
      'reservation_' || p_action,
      initcap(replace(p_action, '_', ' ')),
      coalesce(nullif(trim(p_reason), ''), 'Your reservation attendance was updated.')
    );
  end if;

  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;

  return jsonb_build_object('request_id', p_request_id, 'action_id', null, 'undo_until', null);
end;
$$;

create or replace function public.correct_occurrence_attendance(
  p_occurrence_id uuid,
  p_target_stage text,
  p_reason text,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  occurrence_row public.reservation_occurrences%rowtype;
  request_row public.reservation_requests%rowtype;
  reason_value text := nullif(trim(p_reason), '');
  existing_journal public.reservation_action_journal%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_target_stage not in ('completed', 'no_show') then
    raise exception using errcode = '22023', message = 'Attendance can only be corrected to completed or no-show';
  end if;
  if reason_value is null or length(reason_value) < 3 then
    raise exception using errcode = '22023', message = 'A correction reason is required';
  end if;

  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id
  for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Occurrence not found';
  end if;
  if occurrence_row.lifecycle_stage not in ('completed', 'no_show') then
    raise exception using errcode = '22023', message = 'Only terminal attendance can be corrected';
  end if;
  if occurrence_row.lifecycle_stage = p_target_stage then
    raise exception using errcode = '22023', message = 'Choose a different attendance outcome';
  end if;

  select * into request_row
  from public.reservation_requests
  where id = occurrence_row.request_id
  for update;
  if not public.lock_reservation_admin_scope(request_row.id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    return jsonb_build_object('duplicate', true, 'request_id', request_row.id);
  end if;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  ) values (
    auth.uid(), p_idempotency_key, 'attendance_correction', array[request_row.id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  );

  update public.reservation_occurrences
  set lifecycle_stage = p_target_stage,
      attendance_marked_at = now(),
      attendance_marked_by = auth.uid(),
      attendance_reason = reason_value
  where id = occurrence_row.id;

  perform public.reservation_event(
    request_row.id,
    'attendance corrected',
    reason_value,
    jsonb_build_object(
      'event_key', 'ATTENDANCE_CORRECTED',
      'occurrence_id', occurrence_row.id,
      'from', occurrence_row.lifecycle_stage,
      'to', p_target_stage
    ),
    occurrence_row.id,
    true
  );

  return jsonb_build_object('ok', true, 'request_id', request_row.id);
end;
$$;

create or replace function public.cancel_reservation_action(
  p_request_id uuid,
  p_reason text default null,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
  event_id uuid;
  target_occurrence_id uuid;
  cancelled_count integer;
  remaining_future boolean;
  undoable boolean;
  reason_value text := coalesce(nullif(trim(p_reason), ''), 'Cancelled by requester');
  now_version integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> 'cancel' or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023',
        message = 'That cancellation key was already used for another action';
    end if;
    select not exists (
      select 1 from public.payment_transactions p
      where p.request_id = p_request_id
        and p.status in ('submitted', 'verified', 'refunded')
    ) into undoable;
    return jsonb_build_object(
      'duplicate', true,
      'action_id', case when undoable then existing_journal.id else null end,
      'undo_until', case when undoable then existing_journal.undo_until else null end
    );
  end if;

  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;
  if request_row.status in ('declined', 'cancelled', 'expired')
     or request_row.reservation_status in ('declined', 'cancelled', 'expired', 'completed') then
    raise exception using errcode = '22023', message = 'A terminal reservation cannot be cancelled';
  end if;

  perform 1
  from public.reservation_occurrences
  where request_id = p_request_id
  order by id
  for update;

  if p_payload ? 'occurrence_id' then
    begin
      target_occurrence_id := (p_payload->>'occurrence_id')::uuid;
    exception when invalid_text_representation then
      raise exception using errcode = '22023', message = 'Choose a valid reservation date';
    end;
  end if;

  if not exists (
    select 1
    from public.reservation_occurrences o
    where o.request_id = p_request_id
      and (target_occurrence_id is null or o.id = target_occurrence_id)
      and o.starts_at > now()
      and o.lifecycle_stage = 'booked'
      and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped')
  ) then
    raise exception using errcode = '22023',
      message = 'Only future reservations that have not started can be cancelled';
  end if;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, 'cancel', array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)),
    coalesce((select jsonb_agg(to_jsonb(o) order by o.starts_at)
      from public.reservation_occurrences o
      where o.request_id = p_request_id), '[]'::jsonb)
  returning id into journal_id;

  update public.reservation_occurrences o
  set booking_state = 'cancelled',
      exception_reason = reason_value,
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = reason_value
  where o.request_id = p_request_id
    and (target_occurrence_id is null or o.id = target_occurrence_id)
    and o.starts_at > now()
    and o.lifecycle_stage = 'booked'
    and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped');
  get diagnostics cancelled_count = row_count;
  if cancelled_count = 0 then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;

  select exists (
    select 1
    from public.reservation_occurrences o
    where o.request_id = p_request_id
      and o.starts_at > now()
      and o.lifecycle_stage in ('booked', 'checked_in')
      and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped')
  ) into remaining_future;

  update public.reservation_requests
  set status = case when remaining_future then status else 'cancelled' end,
      reservation_status = case when remaining_future then reservation_status else 'cancelled' end,
      decision_reason = case when remaining_future then decision_reason else reason_value end,
      terminal_at = case when remaining_future then terminal_at else now() end,
      terminal_reason_code = case when remaining_future then terminal_reason_code else null end,
      payment_status = case when not remaining_future and payment_status in ('quoted', 'authorized') then 'voided' else payment_status end,
      payment_due_at = case when remaining_future then payment_due_at else null end,
      balance_due_at = case when remaining_future then balance_due_at else null end,
      updated_at = now()
  where id = p_request_id;

  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;

  event_id := public.reservation_event(
    p_request_id,
    'cancel',
    reason_value,
    jsonb_build_object('occurrence_id', target_occurrence_id, 'cancelled_occurrences', cancelled_count),
    target_occurrence_id,
    true
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_cancel',
    'Reservation cancelled',
    reason_value
  );

  select not exists (
    select 1 from public.payment_transactions p
    where p.request_id = p_request_id
      and p.status in ('submitted', 'verified', 'refunded')
  ) into undoable;

  return jsonb_build_object(
    'request_id', p_request_id,
    'action_id', case when undoable then journal_id else null end,
    'undo_until', case when undoable then now() + interval '8 seconds' else null end
  );
end;
$$;

create or replace function public.reservation_action(
  p_request_id uuid,
  p_action text,
  p_reason text default null,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare result jsonb;
begin
  if p_action = 'cancel' then
    return public.cancel_reservation_action(
      p_request_id, p_reason, p_payload, p_expected_version, p_idempotency_key
    );
  end if;
  if p_action in ('check_in', 'complete', 'no_show') then
    if not (p_payload ? 'occurrence_id') then
      raise exception using errcode = '22023', message = 'Choose a reservation date';
    end if;
    return public.record_occurrence_attendance(
      p_request_id,
      (p_payload->>'occurrence_id')::uuid,
      p_action,
      p_reason,
      p_expected_version,
      p_idempotency_key
    );
  end if;
  if p_action in (
    'approve', 'approve_partial', 'approve_bump', 'decline', 'request_changes',
    'offer_alternative', 'reopen', 'expire'
  ) and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_action in ('accept_alternative', 'resubmit') and not (
    public.lock_reservation_admin_scope(p_request_id) or exists(
      select 1 from public.reservation_requests
      where id = p_request_id and requester_id = auth.uid()
    )
  ) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_action = 'reopen' then
    raise exception using errcode = '22023', message = 'Declined and terminal reservations cannot be reopened';
  end if;

  result := public.reservation_action_unscoped(
    p_request_id, p_action, p_reason, p_payload, p_expected_version, p_idempotency_key);

  if p_action in ('approve', 'approve_partial', 'accept_alternative') then
    perform public.apply_reservation_payment_gate(p_request_id);
  elsif p_action in ('request_changes', 'offer_alternative') then
    update public.reservation_requests set reservation_status = 'changes_requested' where id = p_request_id;
  elsif p_action = 'decline' then
    update public.reservation_requests
    set reservation_status = 'declined', terminal_at = now(), terminal_reason_code = null
    where id = p_request_id;
  elsif p_action = 'expire' then
    update public.reservation_requests
    set reservation_status = 'expired', terminal_at = now(), terminal_reason_code = 'stale_pending'
    where id = p_request_id;
  end if;
  return result;
end;
$$;

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
      end as reason_value,
      case
        when request.reservation_status = 'awaiting_payment'
          then 'down_payment_deadline'
        else 'balance_payment_deadline'
      end as reason_code
    from public.reservation_requests as request
    where not request.legacy_financial_state
      and (
        (
          request.reservation_status = 'awaiting_payment'
          and request.payment_due_at < now()
          and not exists (
            select 1 from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'submitted'
          )
        )
        or (
          request.reservation_status = 'confirmed'
          and request.total_amount_centavos > 0
          and request.balance_due_at < now()
          and not exists (
            select 1 from public.payment_transactions as payment
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
          terminal_at = now(),
          terminal_reason_code = candidate.reason_code,
          decided_at = now()
      where request.id = candidate.id;

      event_id := public.reservation_event(
        candidate.id,
        'expired automatically',
        candidate.reason_value,
        jsonb_build_object('terminal_reason_code', candidate.reason_code),
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

revoke all on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) from public, anon;
revoke all on function public.correct_occurrence_attendance(uuid, text, text, uuid) from public, anon;
revoke all on function public.cancel_reservation_action(uuid, text, jsonb, integer, uuid) from public, anon;
revoke all on function public.reservation_action(uuid, text, text, jsonb, integer, uuid) from public, anon;
revoke all on function public.expire_due_reservations(boolean) from public, anon, authenticated;
grant execute on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) to authenticated;
grant execute on function public.correct_occurrence_attendance(uuid, text, text, uuid) to authenticated;
grant execute on function public.cancel_reservation_action(uuid, text, jsonb, integer, uuid) to authenticated;
grant execute on function public.reservation_action(uuid, text, text, jsonb, integer, uuid) to authenticated;
grant execute on function public.expire_due_reservations(boolean) to service_role;

notify pgrst, 'reload schema';
