-- Make requester cancellation atomic and fail when no future occurrence can
-- actually be cancelled. The public reservation_action signature is kept.

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
    if existing_journal.action <> 'cancel'
       or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023',
        message = 'That cancellation key was already used for another action';
    end if;
    select not exists (
      select 1 from public.payment_transactions p
      where p.request_id = p_request_id
        and p.status in ('submitted','verified','refunded')
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
  if request_row.requester_id <> auth.uid()
     and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001',
      message = 'This reservation changed. Refresh and try again';
  end if;
  if request_row.status in ('declined','cancelled','expired')
     or request_row.reservation_status in ('declined','cancelled','expired','completed') then
    raise exception using errcode = '22023',
      message = 'A terminal reservation cannot be cancelled';
  end if;

  -- Keep the request/occurrence lock order aligned with other reservation
  -- actions and snapshot every occurrence because Undo restores the series.
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
      and o.booking_state in ('requested','held','booked','changes_requested','bumped')
  ) then
    raise exception using errcode = '22023',
      message = 'Only future reservations that have not started can be cancelled';
  end if;

  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids,
    before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, 'cancel', array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)),
    coalesce((select jsonb_agg(to_jsonb(o) order by o.starts_at)
      from public.reservation_occurrences o
      where o.request_id = p_request_id), '[]'::jsonb)
  returning id into journal_id;

  update public.reservation_occurrences o
  set booking_state = 'cancelled', exception_reason = reason_value
  where o.request_id = p_request_id
    and (target_occurrence_id is null or o.id = target_occurrence_id)
    and o.starts_at > now()
    and o.lifecycle_stage = 'booked'
    and o.booking_state in ('requested','held','booked','changes_requested','bumped');
  get diagnostics cancelled_count = row_count;
  if cancelled_count = 0 then
    raise exception using errcode = '40001',
      message = 'This reservation changed. Refresh and try again';
  end if;

  select exists (
    select 1
    from public.reservation_occurrences o
    where o.request_id = p_request_id
      and o.starts_at > now()
      and o.lifecycle_stage in ('booked','checked_in')
      and o.booking_state in ('requested','held','booked','changes_requested','bumped')
  ) into remaining_future;

  update public.reservation_requests
  set status = case when remaining_future then status else 'cancelled' end,
      reservation_status = case when remaining_future
        then reservation_status else 'cancelled' end,
      decision_reason = case when remaining_future
        then decision_reason else reason_value end,
      payment_status = case when not remaining_future
          and payment_status in ('quoted','authorized') then 'voided'
        else payment_status end,
      payment_due_at = case when remaining_future then payment_due_at else null end,
      balance_due_at = case when remaining_future then balance_due_at else null end,
      updated_at = now()
  where id = p_request_id;

  select version into now_version
  from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;

  event_id := public.reservation_event(
    p_request_id,
    'cancel',
    reason_value,
    jsonb_build_object(
      'occurrence_id', target_occurrence_id,
      'cancelled_occurrences', cancelled_count
    ),
    target_occurrence_id,
    true
  );
  perform public.notify_reservation_user(
    p_request_id, event_id, 'reservation_cancel', 'Cancellation saved', reason_value
  );

  select not exists (
    select 1 from public.payment_transactions p
    where p.request_id = p_request_id
      and p.status in ('submitted','verified','refunded')
  ) into undoable;

  return jsonb_build_object(
    'action_id', case when undoable then journal_id else null end,
    'undo_until', case when undoable then (
      select j.undo_until from public.reservation_action_journal j
      where j.id = journal_id
    ) else null end,
    'cancelled_occurrences', cancelled_count
  );
end;
$$;

revoke all on function public.cancel_reservation_action(
  uuid, text, jsonb, integer, uuid
) from public, anon, authenticated;

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
  if p_action in (
    'approve','approve_partial','approve_bump','decline','request_changes',
    'offer_alternative','reopen','expire','check_in','complete','no_show'
  ) and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if p_action in ('accept_alternative','resubmit') and not (
    public.lock_reservation_admin_scope(p_request_id) or exists(
      select 1 from public.reservation_requests
      where id=p_request_id and requester_id=auth.uid()
    )
  ) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if p_action='reopen' then
    raise exception using errcode='22023',message='Declined and terminal reservations cannot be reopened';
  end if;
  if p_action in ('check_in','complete','no_show') and not exists(
    select 1 from public.reservation_requests
    where id=p_request_id and reservation_status='confirmed'
  ) then
    raise exception using errcode='22023',message='Only a confirmed reservation can enter facility use';
  end if;
  result:=public.reservation_action_unscoped(
    p_request_id,p_action,p_reason,p_payload,p_expected_version,p_idempotency_key);
  if p_action in ('approve','approve_partial','accept_alternative') then
    perform public.apply_reservation_payment_gate(p_request_id);
  elsif p_action in ('request_changes','offer_alternative') then
    update public.reservation_requests set reservation_status='changes_requested' where id=p_request_id;
  elsif p_action='decline' then
    update public.reservation_requests set reservation_status='declined' where id=p_request_id;
  elsif p_action='reopen' then
    update public.reservation_requests set reservation_status='pending_approval' where id=p_request_id;
  elsif p_action='expire' then
    update public.reservation_requests set reservation_status='expired' where id=p_request_id;
  elsif p_action in ('complete','no_show') and not exists(
    select 1 from public.reservation_occurrences
    where request_id=p_request_id and lifecycle_stage not in ('completed','no_show')
  ) then
    update public.reservation_requests set reservation_status='completed' where id=p_request_id;
  end if;
  return result;
end;
$$;

revoke all on function public.reservation_action(
  uuid, text, text, jsonb, integer, uuid
) from public, anon;
grant execute on function public.reservation_action(
  uuid, text, text, jsonb, integer, uuid
) to authenticated;

-- Requesters may undo their own cancellation. Other actions retain assigned
-- administrator scope, and payment activity remains non-reversible.
create or replace function public.undo_reservation_action(p_action_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  journal public.reservation_action_journal%rowtype;
  item jsonb;
  snapshot public.reservation_requests%rowtype;
  occurrence public.reservation_occurrences%rowtype;
  request_id_value uuid;
begin
  select * into journal from public.reservation_action_journal
  where id = p_action_id for update;
  if journal.id is null or journal.actor_id <> auth.uid() then
    raise exception using errcode='42501',message='Undo is not available';
  end if;
  if journal.undone_at is not null or now() > journal.undo_until then
    raise exception using errcode='22023',message='The undo window has ended';
  end if;
  foreach request_id_value in array journal.request_ids loop
    if not public.lock_reservation_admin_scope(request_id_value)
       and not (
         journal.action = 'cancel' and exists(
           select 1 from public.reservation_requests r
           where r.id = request_id_value and r.requester_id = auth.uid()
         )
       ) then
      raise exception using errcode='42501',message='Reservation access denied';
    end if;
    if exists(select 1 from public.payment_transactions p
      where p.request_id = request_id_value
        and p.status in ('submitted','verified','refunded')) then
      raise exception using errcode='22023',
        message='An action with payment activity cannot be undone';
    end if;
  end loop;
  for item in select value from jsonb_array_elements(journal.before_requests) loop
    snapshot := jsonb_populate_record(null::public.reservation_requests, item);
    update public.reservation_requests set
      status = snapshot.status,
      reservation_status = snapshot.reservation_status,
      held_for_verification = snapshot.held_for_verification,
      decision_reason = snapshot.decision_reason,
      decided_by = snapshot.decided_by,
      decided_by_name = snapshot.decided_by_name,
      decided_at = snapshot.decided_at,
      payment_status = snapshot.payment_status,
      payment_method_id = snapshot.payment_method_id,
      payment_due_at = snapshot.payment_due_at,
      balance_due_at = snapshot.balance_due_at
    where id = snapshot.id;
  end loop;
  delete from public.reservation_occurrences
  where request_id = any(journal.request_ids);
  for item in select value from jsonb_array_elements(journal.before_occurrences) loop
    occurrence := jsonb_populate_record(null::public.reservation_occurrences, item);
    insert into public.reservation_occurrences(
      id,request_id,facility_id,starts_at,ends_at,buffer_minutes,
      booking_state,lifecycle_stage,proposed_starts_at,proposed_ends_at,
      exception_reason,created_at,updated_at
    ) values (
      occurrence.id,occurrence.request_id,occurrence.facility_id,
      occurrence.starts_at,occurrence.ends_at,occurrence.buffer_minutes,
      occurrence.booking_state,occurrence.lifecycle_stage,
      occurrence.proposed_starts_at,occurrence.proposed_ends_at,
      occurrence.exception_reason,occurrence.created_at,now()
    );
  end loop;
  update public.reservation_action_journal set undone_at = now()
  where id = journal.id;
  perform public.reservation_event(
    journal.request_ids[1], 'undid ' || replace(journal.action,'_',' '),
    null, jsonb_build_object('action_id',journal.id)
  );
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.undo_reservation_action(uuid) from public, anon;
grant execute on function public.undo_reservation_action(uuid) to authenticated;

-- Repair only rows that demonstrably had a cancellation applied and no
-- future active occurrence remains. Pure no-op events are intentionally not
-- interpreted as a historical cancellation request.
update public.reservation_requests r
set status = 'cancelled',
    reservation_status = 'cancelled',
    decision_reason = coalesce(r.decision_reason, 'Cancelled by requester'),
    payment_status = case when r.payment_status in ('quoted','authorized')
      then 'voided' else r.payment_status end,
    payment_due_at = null,
    balance_due_at = null,
    updated_at = now()
where (r.status <> 'cancelled' or r.reservation_status <> 'cancelled')
  and exists (
    select 1 from public.reservation_occurrences o
    where o.request_id = r.id and o.booking_state = 'cancelled'
  )
  and exists (
    select 1 from public.reservation_events e
    where e.request_id = r.id and e.action = 'cancel'
  )
  and not exists (
    select 1 from public.reservation_occurrences o
    where o.request_id = r.id
      and o.starts_at > now()
      and o.lifecycle_stage in ('booked','checked_in')
      and o.booking_state in ('requested','held','booked','changes_requested','bumped')
  );

notify pgrst, 'reload schema';
