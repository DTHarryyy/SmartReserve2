-- Let a requester move a future occurrence without cancelling the whole
-- reservation. The old hold is released and the replacement schedule returns
-- to the same administrator lane for approval. Payment-free reservations may
-- also choose a new duration within the facility maximum. Paid reservations
-- keep their quoted duration; permits/signatures are invalidated by the
-- request-version trigger.
create or replace function public.request_reservation_reschedule(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_reason text,
  p_expected_version integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  facility_row public.facilities%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
  event_id uuid;
  now_version integer;
  local_start timestamp;
  local_end timestamp;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> 'request_reschedule'
       or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using
        errcode = '22023',
        message = 'That reschedule key was already used for another action';
    end if;
    return jsonb_build_object(
      'duplicate', true,
      'request_id', p_request_id,
      'action_id', null
    );
  end if;

  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.status not in ('pending', 'approved')
     or request_row.reservation_status not in (
       'pending_approval', 'awaiting_payment', 'confirmed'
     ) then
    raise exception using
      errcode = '22023',
      message = 'This reservation cannot be rescheduled';
  end if;
  if request_row.version <> p_expected_version then
    raise exception using
      errcode = '40001',
      message = 'This reservation changed. Refresh and try again';
  end if;

  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation date not found';
  end if;
  if occurrence_row.starts_at <= now()
     or occurrence_row.lifecycle_stage <> 'booked'
     or occurrence_row.booking_state not in ('requested', 'held', 'booked') then
    raise exception using
      errcode = '22023',
      message = 'Only a future reservation that has not started can be rescheduled';
  end if;

  if nullif(trim(p_reason), '') is null or length(trim(p_reason)) > 300 then
    raise exception using
      errcode = '22023',
      message = 'Add a brief reason for the reschedule request';
  end if;
  if p_starts_at is null or p_ends_at is null
     or p_starts_at >= p_ends_at or p_starts_at <= now() then
    raise exception using errcode = '22023', message = 'Choose a valid future time';
  end if;
  if p_starts_at = occurrence_row.starts_at
     and p_ends_at = occurrence_row.ends_at then
    raise exception using errcode = '22023', message = 'Choose a different schedule';
  end if;
  if request_row.total_amount_centavos > 0
     and p_ends_at - p_starts_at <>
       occurrence_row.ends_at - occurrence_row.starts_at then
    raise exception using
      errcode = '22023',
      message = 'A paid reservation must keep the original duration';
  end if;

  select * into facility_row
  from public.facilities
  where id = request_row.facility_id and archived_at is null;
  if facility_row.id is null or facility_row.status <> 'active' then
    raise exception using errcode = '22023', message = 'This facility is unavailable';
  end if;
  if extract(epoch from (p_ends_at - p_starts_at)) / 60
       > facility_row.max_duration_minutes then
    raise exception using
      errcode = '22023',
      message = 'Reservation exceeds the facility maximum duration';
  end if;
  local_start := p_starts_at at time zone 'Asia/Manila';
  local_end := p_ends_at at time zone 'Asia/Manila';
  if local_start::date <> local_end::date
     or not facility_row.open_days[extract(isodow from local_start)::integer]
     or local_start::time < facility_row.open_time
     or local_end::time > facility_row.close_time then
    raise exception using
      errcode = '22023',
      message = 'Choose a time within the facility schedule';
  end if;
  if p_starts_at > now() + make_interval(days => facility_row.advance_booking_days) then
    raise exception using
      errcode = '22023',
      message = 'The new schedule is too far in advance for this facility';
  end if;

  insert into public.reservation_action_journal(
    actor_id,
    idempotency_key,
    action,
    request_ids,
    before_requests,
    before_occurrences
  ) values (
    auth.uid(),
    p_idempotency_key,
    'request_reschedule',
    array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)),
    jsonb_build_array(to_jsonb(occurrence_row))
  ) returning id into journal_id;

  update public.reservation_occurrences
  set starts_at = p_starts_at,
      ends_at = p_ends_at,
      booking_state = 'requested',
      lifecycle_stage = 'booked',
      proposed_starts_at = null,
      proposed_ends_at = null,
      exception_reason = 'Requester asked to reschedule: ' || trim(p_reason)
  where id = p_occurrence_id;

  update public.reservation_requests
  set status = 'pending',
      reservation_status = 'pending_approval',
      decision_reason = 'Requester asked to reschedule: ' || trim(p_reason),
      decided_by = null,
      decided_by_name = null,
      decided_at = null,
      terminal_at = null,
      terminal_reason_code = null
  where id = p_request_id;

  select version into now_version
  from public.reservation_requests
  where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version),
      undo_until = now()
  where id = journal_id;

  event_id := public.reservation_event(
    p_request_id,
    'requested a reservation reschedule',
    trim(p_reason),
    jsonb_build_object(
      'occurrence_id', p_occurrence_id,
      'previous_starts_at', occurrence_row.starts_at,
      'previous_ends_at', occurrence_row.ends_at,
      'starts_at', p_starts_at,
      'ends_at', p_ends_at
    ),
    p_occurrence_id,
    true
  );

  insert into public.app_notifications(
    recipient_id, request_id, event_id, kind, title, body
  )
  select
    profile.id,
    p_request_id,
    event_id,
    'reservation_reschedule_requested',
    'Reschedule request',
    request_row.requester_name || ' requested a new time for ' ||
      request_row.facility_name
  from public.profiles profile
  where profile.account_status = 'active'
    and profile.role = case request_row.admin_lane
      when 'internal' then 'internal_admin'
      else 'external_admin'
    end;

  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_reschedule_sent',
    'Reschedule request sent',
    'Your old slot was released. The new schedule is waiting for admin approval.'
  );

  return jsonb_build_object(
    'request_id', p_request_id,
    'occurrence_id', p_occurrence_id,
    'action_id', null
  );
end;
$$;

revoke all on function public.request_reservation_reschedule(
  uuid, uuid, timestamptz, timestamptz, text, integer, uuid
) from public, anon;
grant execute on function public.request_reservation_reschedule(
  uuid, uuid, timestamptz, timestamptz, text, integer, uuid
) to authenticated;

notify pgrst, 'reload schema';
