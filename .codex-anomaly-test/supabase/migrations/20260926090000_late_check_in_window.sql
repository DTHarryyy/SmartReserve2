-- Widen the self check-in window from a 15-minute to a 30-minute grace period
-- after the booking start, and record how many minutes late a check-in was
-- instead of simply locking latecomers out. The admin no-show grace moves to
-- the same 30 minutes so admins can never mark a no-show while the requester
-- could still legitimately check in.

-- ---------------------------------------------------------------------
-- 1. Track when an occurrence was checked in, and how late it was.
-- ---------------------------------------------------------------------

alter table public.reservation_occurrences
  add column if not exists checked_in_at timestamptz,
  add column if not exists check_in_late_minutes integer
    check (check_in_late_minutes is null or check_in_late_minutes >= 0);

-- Best-effort backfill for occurrences already checked in, mirroring the
-- attendance backfill in 20260829110000_attendance_and_terminal_outcomes.sql.
with first_check_in as (
  select e.occurrence_id, min(e.created_at) as checked_in_at
  from public.reservation_events e
  where e.occurrence_id is not null
    and e.action in ('self check in', 'check in')
  group by e.occurrence_id
)
update public.reservation_occurrences o
set checked_in_at = f.checked_in_at,
    check_in_late_minutes = greatest(
      0,
      ceil(extract(epoch from (f.checked_in_at - o.starts_at)) / 60)
    )::integer
from first_check_in f
where f.occurrence_id = o.id
  and o.checked_in_at is null
  and o.lifecycle_stage in ('checked_in', 'completed');

-- ---------------------------------------------------------------------
-- 2. Requester self check-in: 30 minutes before through 30 minutes after,
--    recording lateness on the occurrence and in the event trail.
-- ---------------------------------------------------------------------

create or replace function public.self_check_in_occurrence(
  p_request_id uuid,
  p_occurrence_id uuid,
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
  journal_id uuid;
  event_id uuid;
  late_minutes integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only confirmed reservations can be checked in';
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
  if occurrence_row.lifecycle_stage <> 'booked' then
    raise exception using errcode = '22023', message = 'This occurrence has already been checked in or closed';
  end if;
  if now() < occurrence_row.starts_at - interval '30 minutes' then
    raise exception using errcode = '22023', message = 'Check-in opens 30 minutes before the booking';
  end if;
  if now() > occurrence_row.starts_at + interval '30 minutes' then
    raise exception using errcode = '22023', message = 'Check-in closed 30 minutes after the booking start';
  end if;
  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    return jsonb_build_object('duplicate', true, 'request_id', p_request_id);
  end if;
  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  values (
    auth.uid(), p_idempotency_key, 'self_check_in', array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  )
  returning id into journal_id;
  late_minutes := greatest(
    0,
    ceil(extract(epoch from (now() - occurrence_row.starts_at)) / 60)
  )::integer;
  update public.reservation_occurrences
  set lifecycle_stage = 'checked_in',
      checked_in_at = now(),
      check_in_late_minutes = late_minutes
  where id = occurrence_row.id;
  update public.reservation_requests
  set payment_status = case when payment_status = 'authorized' then 'captured' else payment_status end
  where id = p_request_id;
  event_id := public.reservation_event(
    p_request_id,
    'self check in',
    case when late_minutes > 0
      then format('Late by %s minute%s.', late_minutes,
                  case when late_minutes = 1 then '' else 's' end)
    end,
    jsonb_build_object(
      'occurrence_id', occurrence_row.id,
      'actor', 'requester',
      'late_minutes', late_minutes
    ),
    occurrence_row.id,
    false
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_self_check_in',
    case when late_minutes > 0 then 'Checked in late' else 'Checked in' end,
    case when late_minutes > 0
      then format('Your facility check-in was recorded %s minute%s late.',
                  late_minutes, case when late_minutes = 1 then '' else 's' end)
      else 'Your facility check-in was recorded.'
    end
  );
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, (select version from public.reservation_requests where id = p_request_id))
  where id = journal_id;
  return jsonb_build_object(
    'request_id', p_request_id,
    'occurrence_id', p_occurrence_id,
    'late_minutes', late_minutes,
    'action_id', null
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Admin no-show grace: 15 -> 30 minutes, so it never fires while
--    self check-in is still open.
-- ---------------------------------------------------------------------

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
  journal_id uuid;
  event_id uuid;
  target_stage text;
  now_version integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_action not in ('complete', 'no_show') then
    raise exception using errcode = '22023', message = 'Administrator attendance can only complete or mark no-show. Requesters use self check-in.';
  end if;
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> p_action or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023', message = 'That attendance key was already used for another action';
    end if;
    return jsonb_build_object('duplicate', true, 'action_id', null, 'undo_until', null);
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
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
  if p_action = 'complete' and occurrence_row.lifecycle_stage <> 'checked_in' then
    raise exception using errcode = '22023', message = 'Check in before completing this booking';
  end if;
  if p_action = 'no_show' and now() < occurrence_row.starts_at + interval '30 minutes' then
    raise exception using errcode = '22023', message = 'The no-show grace period has not ended';
  end if;
  target_stage := case p_action when 'complete' then 'completed' else 'no_show' end;
  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, p_action, array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  returning id into journal_id;
  update public.reservation_occurrences
  set lifecycle_stage = target_stage,
      attendance_marked_at = now(),
      attendance_marked_by = auth.uid(),
      attendance_reason = nullif(trim(p_reason), '')
  where id = occurrence_row.id;
  if p_action = 'complete' then
    perform public.settle_loyalty_occurrence(occurrence_row.id, 'completed', null);
  end if;
  if not exists (
    select 1 from public.reservation_occurrences
    where request_id = p_request_id
      and lifecycle_stage not in ('completed', 'no_show')
  ) then
    update public.reservation_requests
    set reservation_status = 'completed'
    where id = p_request_id;
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'consume', p_action);
  end if;
  event_id := public.reservation_event(
    p_request_id,
    replace(p_action, '_', ' '),
    p_reason,
    jsonb_build_object('occurrence_id', occurrence_row.id),
    occurrence_row.id,
    true
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_' || p_action,
    initcap(replace(p_action, '_', ' ')),
    coalesce(nullif(trim(p_reason), ''), 'Your reservation attendance was updated.')
  );
  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;
  return jsonb_build_object('request_id', p_request_id, 'action_id', null, 'undo_until', null);
end;
$$;

revoke all on function public.self_check_in_occurrence(uuid, uuid, integer, uuid) from public, anon;
revoke all on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) from public, anon;
grant execute on function public.self_check_in_occurrence(uuid, uuid, integer, uuid) to authenticated;
grant execute on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Requester history: count late check-ins over the trailing 30 days,
--    alongside the existing no-show / late-cancellation counters.
-- ---------------------------------------------------------------------

alter table public.renter_risk_profiles
  add column if not exists late_check_ins_30d integer not null default 0;

create or replace function public.recalculate_renter_risk_profiles(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now()
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  changed_count integer := 0;
begin
  with facilities_in_scope as (
    select distinct facility_id
    from public.reservation_requests
    where requester_id = p_renter_id
      and admin_lane = p_admin_lane
      and created_at >= p_as_of - interval '180 days'
    union
    select distinct facility_id
    from public.reservation_anomalies
    where renter_id = p_renter_id
      and admin_lane = p_admin_lane
  ), visible_cases as (
    select
      a.*,
      case ar.signal_family
        when 'attendance' then 40
        when 'creation' then 15
        when 'cancellation' then 30
        when 'overlap' then 20
        when 'duration' then 15
        when 'hoarding' then 25
        when 'payment' then 35
        else 15
      end as family_cap,
      ar.signal_family,
      public.anomaly_decayed_points(a.base_risk_points, a.last_contributing_at, p_as_of) as decayed_points
    from public.reservation_anomalies a
    join public.anomaly_rules ar on ar.rule_key = a.rule_key
    where a.renter_id = p_renter_id
      and a.admin_lane = p_admin_lane
      and a.detection_mode = 'active'
      and a.status in ('open', 'acknowledged')
  ), per_facility_case as (
    select distinct on (facility_id, correlation_key)
      facility_id, signal_family, family_cap, decayed_points, last_contributing_at
    from visible_cases
    order by facility_id, correlation_key, decayed_points desc
  ), family_scores as (
    select facility_id, signal_family, least(max(family_cap), sum(decayed_points))::integer as family_score
    from per_facility_case
    group by facility_id, signal_family
  ), adverse as (
    select facility_id, max(last_contributing_at) as last_adverse_at
    from per_facility_case
    group by facility_id
  ), aggregates as (
    select
      f.facility_id,
      coalesce((select count(*) from public.reservation_anomalies a
        where a.renter_id = p_renter_id and a.admin_lane = p_admin_lane
          and a.facility_id = f.facility_id and a.detection_mode = 'active'
          and a.status in ('open', 'acknowledged')), 0)::integer as active_anomaly_count,
      coalesce((select sum(family_score) from family_scores fs where fs.facility_id = f.facility_id), 0)::integer as raw_score,
      coalesce((select count(*) from public.reservation_requests r
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and r.facility_id = f.facility_id and r.created_at >= p_as_of - interval '30 days'), 0)::integer as reservations_30d,
      coalesce((select count(*) from public.reservation_occurrences o
        join public.reservation_requests r on r.id = o.request_id
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and o.facility_id = f.facility_id and o.lifecycle_stage = 'completed'
          and o.attendance_marked_at >= p_as_of - interval '30 days'), 0)::integer as successful_occurrences_30d,
      coalesce((select count(*) from public.reservation_occurrences o
        join public.reservation_requests r on r.id = o.request_id
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and o.facility_id = f.facility_id and o.lifecycle_stage = 'no_show'
          and o.attendance_marked_at >= p_as_of - interval '30 days'), 0)::integer as no_show_occurrences_30d,
      coalesce((select count(*) from public.reservation_occurrences o
        join public.reservation_requests r on r.id = o.request_id
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and o.facility_id = f.facility_id
          and coalesce(o.check_in_late_minutes, 0) > 0
          and o.checked_in_at >= p_as_of - interval '30 days'), 0)::integer as late_check_ins_30d,
      coalesce((select count(*) from public.reservation_occurrences o
        join public.reservation_requests r on r.id = o.request_id
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and o.facility_id = f.facility_id and o.cancelled_at >= p_as_of - interval '30 days'), 0)::integer as cancelled_occurrences_30d,
      coalesce((select count(*) from public.reservation_occurrences o
        join public.reservation_requests r on r.id = o.request_id
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and o.facility_id = f.facility_id and o.cancelled_at >= p_as_of - interval '30 days'
          and o.cancelled_at > o.starts_at - interval '12 hours'), 0)::integer as late_cancellations_30d,
      coalesce((select count(*) from public.reservation_requests r
        where r.requester_id = p_renter_id and r.admin_lane = p_admin_lane
          and r.facility_id = f.facility_id and r.terminal_reason_code in ('down_payment_deadline', 'balance_payment_deadline')
          and r.terminal_at >= p_as_of - interval '30 days'), 0)::integer as payment_expirations_30d,
      (select last_adverse_at from adverse a where a.facility_id = f.facility_id) as last_adverse_at
    from facilities_in_scope f
  ), scored as (
    select
      a.*,
      least(15, 3 * coalesce((
        select count(*)
        from public.reservation_occurrences o
        join public.reservation_requests r on r.id = o.request_id
        where r.requester_id = p_renter_id
          and r.admin_lane = p_admin_lane
          and o.facility_id = a.facility_id
          and o.lifecycle_stage = 'completed'
          and o.attendance_marked_at >= coalesce(a.last_adverse_at, p_as_of - interval '90 days')
          and o.attendance_marked_at >= p_as_of - interval '90 days'
      ), 0))::integer as success_credit
    from aggregates a
  ), upserted as (
    insert into public.renter_risk_profiles(
      renter_id, admin_lane, facility_id, local_risk_score, local_risk_level,
      active_anomaly_count, reservations_30d, successful_occurrences_30d,
      no_show_occurrences_30d, late_check_ins_30d, cancelled_occurrences_30d, late_cancellations_30d,
      payment_expirations_30d, last_adverse_at, last_evaluated_at
    )
    select
      p_renter_id,
      p_admin_lane,
      facility_id,
      greatest(0, least(100, round(raw_score - success_credit)::integer)),
      public.anomaly_risk_level(greatest(0, least(100, round(raw_score - success_credit)::integer))),
      active_anomaly_count,
      reservations_30d,
      successful_occurrences_30d,
      no_show_occurrences_30d,
      late_check_ins_30d,
      cancelled_occurrences_30d,
      late_cancellations_30d,
      payment_expirations_30d,
      last_adverse_at,
      p_as_of
    from scored
    on conflict (renter_id, admin_lane, facility_id) do update
    set local_risk_score = excluded.local_risk_score,
        local_risk_level = excluded.local_risk_level,
        active_anomaly_count = excluded.active_anomaly_count,
        reservations_30d = excluded.reservations_30d,
        successful_occurrences_30d = excluded.successful_occurrences_30d,
        no_show_occurrences_30d = excluded.no_show_occurrences_30d,
        late_check_ins_30d = excluded.late_check_ins_30d,
        cancelled_occurrences_30d = excluded.cancelled_occurrences_30d,
        late_cancellations_30d = excluded.late_cancellations_30d,
        payment_expirations_30d = excluded.payment_expirations_30d,
        last_adverse_at = excluded.last_adverse_at,
        last_evaluated_at = excluded.last_evaluated_at
    returning 1
  )
  select count(*) into changed_count from upserted;

  return changed_count;
end;
$$;

revoke all on function public.recalculate_renter_risk_profiles(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.recalculate_renter_risk_profiles(uuid, text, timestamptz) to service_role;

-- scoped_risk_summary is the single source both get_reservation_risk_summary
-- and evaluate_reservation_risk_now delegate to, so extending it here covers
-- both call sites the client uses.
create or replace function public.scoped_risk_summary(
  p_renter_id uuid,
  p_admin_lane text
) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with scoped_profiles as (
    select p.*
    from public.renter_risk_profiles p
    where p.renter_id = p_renter_id
      and p.admin_lane = p_admin_lane
      and public.admin_lane() = p.admin_lane
      and public.can_manage_facility(p.facility_id)
  ), visible_cases as (
    select distinct on (a.correlation_key)
      a.id,
      a.rule_key,
      a.title,
      a.explanation,
      a.severity,
      a.effective_risk_points,
      a.last_contributing_at,
      a.last_evaluated_at
    from public.reservation_anomalies a
    where a.renter_id = p_renter_id
      and a.admin_lane = p_admin_lane
      and a.detection_mode = 'active'
      and a.status in ('open', 'acknowledged')
      and public.admin_lane() = a.admin_lane
      and public.can_manage_facility(a.facility_id)
    order by a.correlation_key, a.effective_risk_points desc, a.last_detected_at desc
  ), family_scores as (
    select
      ar.signal_family,
      case ar.signal_family
        when 'attendance' then 40
        when 'creation' then 15
        when 'cancellation' then 30
        when 'overlap' then 20
        when 'duration' then 15
        when 'hoarding' then 25
        when 'payment' then 35
        else 15
      end as family_cap,
      sum(v.effective_risk_points)::integer as family_points
    from visible_cases v
    join public.anomaly_rules ar on ar.rule_key = v.rule_key
    group by ar.signal_family
  ), totals as (
    select least(100, greatest(0, coalesce(sum(least(family_cap, family_points)), 0)))::integer as score
    from family_scores
  )
  select jsonb_build_object(
    'renter_id', p_renter_id,
    'admin_lane', p_admin_lane,
    'risk_score', coalesce((select score from totals), 0),
    'risk_level', public.anomaly_risk_level(coalesce((select score from totals), 0)),
    'active_anomaly_count', coalesce((select count(*) from visible_cases), 0),
    'reservations_30d', coalesce((select sum(reservations_30d) from scoped_profiles), 0),
    'successful_occurrences_30d', coalesce((select sum(successful_occurrences_30d) from scoped_profiles), 0),
    'no_show_occurrences_30d', coalesce((select sum(no_show_occurrences_30d) from scoped_profiles), 0),
    'late_check_ins_30d', coalesce((select sum(late_check_ins_30d) from scoped_profiles), 0),
    'cancelled_occurrences_30d', coalesce((select sum(cancelled_occurrences_30d) from scoped_profiles), 0),
    'late_cancellations_30d', coalesce((select sum(late_cancellations_30d) from scoped_profiles), 0),
    'payment_expirations_30d', coalesce((select sum(payment_expirations_30d) from scoped_profiles), 0),
    'last_adverse_at', (select max(last_adverse_at) from scoped_profiles),
    'last_evaluated_at', nullif(
      greatest(
        coalesce((select max(last_evaluated_at) from scoped_profiles), '-infinity'::timestamptz),
        coalesce((select max(last_evaluated_at) from visible_cases), '-infinity'::timestamptz)
      ),
      '-infinity'::timestamptz
    ),
    'top_reasons', coalesce((
      select jsonb_agg(jsonb_build_object(
        'anomaly_id', id,
        'rule_key', rule_key,
        'title', title,
        'explanation', explanation,
        'severity', severity,
        'points', effective_risk_points
      ) order by effective_risk_points desc, last_contributing_at desc)
      from (select * from visible_cases order by effective_risk_points desc, last_contributing_at desc limit 3) top
    ), '[]'::jsonb),
    'portfolio_label', 'Risk in your assigned portfolio',
    'evaluation_pending', exists (
      select 1 from public.reservation_anomaly_evaluation_queue q
      where q.renter_id = p_renter_id and q.admin_lane = p_admin_lane
        and q.next_attempt_at <= now() + interval '2 minutes'
    ),
    'evaluation_stalled', exists (
      select 1 from public.reservation_anomaly_evaluation_queue q
      where q.renter_id = p_renter_id and q.admin_lane = p_admin_lane
        and q.attempt_count >= 3
    )
  );
$$;

revoke all on function public.scoped_risk_summary(uuid, text) from public, anon, authenticated;
