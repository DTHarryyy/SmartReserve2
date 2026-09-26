create or replace function public.queue_reservation_anomaly_from_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT'
     or new.reservation_status is distinct from old.reservation_status
     or new.terminal_reason_code is distinct from old.terminal_reason_code
     or new.terminal_at is distinct from old.terminal_at then
    perform public.enqueue_reservation_anomaly_evaluation(
      new.requester_id,
      new.admin_lane,
      array['reservation_request', coalesce(new.terminal_reason_code, new.reservation_status)]
    );
  end if;
  return new;
end;
$$;

create or replace function public.queue_reservation_anomaly_from_occurrence()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
begin
  select * into request_row from public.reservation_requests where id = new.request_id;
  if request_row.id is null then
    return new;
  end if;
  if tg_op = 'INSERT'
     or new.lifecycle_stage is distinct from old.lifecycle_stage
     or new.booking_state is distinct from old.booking_state
     or new.cancelled_at is distinct from old.cancelled_at
     or new.attendance_marked_at is distinct from old.attendance_marked_at then
    perform public.enqueue_reservation_anomaly_evaluation(
      request_row.requester_id,
      request_row.admin_lane,
      array['reservation_occurrence', new.lifecycle_stage, new.booking_state]
    );
  end if;
  return new;
end;
$$;

create or replace function public.queue_reservation_anomaly_from_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
begin
  select * into request_row from public.reservation_requests where id = new.request_id;
  if request_row.id is not null then
    perform public.enqueue_reservation_anomaly_evaluation(
      request_row.requester_id,
      request_row.admin_lane,
      array['payment_transaction', new.status]
    );
  end if;
  return new;
end;
$$;

drop trigger if exists reservation_requests_anomaly_queue on public.reservation_requests;
create trigger reservation_requests_anomaly_queue
after insert or update of reservation_status, terminal_reason_code, terminal_at
on public.reservation_requests
for each row execute procedure public.queue_reservation_anomaly_from_request();

drop trigger if exists reservation_occurrences_anomaly_queue on public.reservation_occurrences;
create trigger reservation_occurrences_anomaly_queue
after insert or update of lifecycle_stage, booking_state, cancelled_at, attendance_marked_at
on public.reservation_occurrences
for each row execute procedure public.queue_reservation_anomaly_from_occurrence();

drop trigger if exists payment_transactions_anomaly_queue on public.payment_transactions;
create trigger payment_transactions_anomaly_queue
after insert or update of status
on public.payment_transactions
for each row execute procedure public.queue_reservation_anomaly_from_payment();

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
    'cancelled_occurrences_30d', coalesce((select sum(cancelled_occurrences_30d) from scoped_profiles), 0),
    'late_cancellations_30d', coalesce((select sum(late_cancellations_30d) from scoped_profiles), 0),
    'payment_expirations_30d', coalesce((select sum(payment_expirations_30d) from scoped_profiles), 0),
    'last_adverse_at', (select max(last_adverse_at) from scoped_profiles),
    'last_evaluated_at', greatest(
      coalesce((select max(last_evaluated_at) from scoped_profiles), '-infinity'::timestamptz),
      coalesce((select max(last_evaluated_at) from visible_cases), '-infinity'::timestamptz)
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
    )
  );
$$;

create or replace function public.get_reservation_risk_summary(
  p_request_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
begin
  if not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  return public.scoped_risk_summary(request_row.requester_id, request_row.admin_lane)
    || jsonb_build_object('request_id', request_row.id, 'facility_id', request_row.facility_id);
end;
$$;

create or replace function public.get_anomaly_center(
  p_filters jsonb default '{}'::jsonb,
  p_cursor jsonb default null,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  lane_value text := public.admin_lane();
  limit_value integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  before_detected_at timestamptz := null;
  before_id uuid := null;
  include_observe boolean := coalesce((p_filters->>'include_observe')::boolean, false);
  status_values text[] := coalesce(
    array(select jsonb_array_elements_text(coalesce(p_filters->'statuses', '["open","acknowledged"]'::jsonb))),
    array['open','acknowledged']
  );
  severity_values text[] := coalesce(
    array(select jsonb_array_elements_text(coalesce(p_filters->'severities', '[]'::jsonb))),
    '{}'::text[]
  );
  rule_values text[] := coalesce(
    array(select jsonb_array_elements_text(coalesce(p_filters->'rules', '[]'::jsonb))),
    '{}'::text[]
  );
  result_value jsonb;
begin
  if lane_value is null then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_cursor is not null then
    before_detected_at := nullif(p_cursor->>'last_detected_at', '')::timestamptz;
    before_id := nullif(p_cursor->>'id', '')::uuid;
  end if;

  with scoped as (
    select
      a.*,
      prof.full_name as renter_name,
      prof.email as renter_email,
      f.name as facility_name,
      f.building as facility_building,
      coalesce(rp.local_risk_score, 0) as local_risk_score,
      coalesce(rp.local_risk_level, 'normal') as local_risk_level
    from public.reservation_anomalies a
    join public.profiles prof on prof.id = a.renter_id
    join public.facilities f on f.id = a.facility_id
    left join public.renter_risk_profiles rp
      on rp.renter_id = a.renter_id
     and rp.admin_lane = a.admin_lane
     and rp.facility_id = a.facility_id
    where a.admin_lane = lane_value
      and public.can_manage_facility(a.facility_id)
      and (include_observe or a.detection_mode = 'active')
      and a.status = any(status_values)
      and (array_length(severity_values, 1) is null or a.severity = any(severity_values))
      and (array_length(rule_values, 1) is null or a.rule_key = any(rule_values))
  ), page as (
    select *
    from scoped
    where before_detected_at is null
      or (last_detected_at, id) < (before_detected_at, before_id)
    order by last_detected_at desc, id desc
    limit limit_value
  ), metrics as (
    select jsonb_build_object(
      'open_count', count(*) filter (where status = 'open' and detection_mode = 'active'),
      'acknowledged_count', count(*) filter (where status = 'acknowledged' and detection_mode = 'active'),
      'high_count', count(*) filter (where severity = 'high' and detection_mode = 'active' and status in ('open','acknowledged')),
      'critical_count', count(*) filter (where severity = 'critical' and detection_mode = 'active' and status in ('open','acknowledged')),
      'observe_count', count(*) filter (where detection_mode = 'observe'),
      'payment_count', count(*) filter (where rule_key in ('missed_down_payment','payment_deadline_expiration','full_payment_deadline_failure','payment_slot_blocking')),
      'needs_review_count', count(*) filter (where status = 'open' and severity in ('high','critical') and detection_mode = 'active')
    ) as value
    from scoped
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(
        to_jsonb(page) - 'renter_email'
        order by page.last_detected_at desc, page.id desc
      )
      from page
    ), '[]'::jsonb),
    'metrics', coalesce((select value from metrics), '{}'::jsonb),
    'next_cursor', (
      select case when count(*) = limit_value then
        jsonb_build_object('last_detected_at', min(last_detected_at), 'id', (array_agg(id order by last_detected_at asc, id asc))[1])
      else null end
      from page
    ),
    'lane', lane_value
  ) into result_value;
  return result_value;
end;
$$;

create or replace function public.get_anomaly_detail(
  p_anomaly_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  anomaly_row public.reservation_anomalies%rowtype;
  result_value jsonb;
begin
  select * into anomaly_row
  from public.reservation_anomalies
  where id = p_anomaly_id;
  if anomaly_row.id is null
     or public.admin_lane() <> anomaly_row.admin_lane
     or not public.can_manage_facility(anomaly_row.facility_id) then
    raise exception using errcode = '42501', message = 'Anomaly access denied';
  end if;

  select jsonb_build_object(
    'anomaly', to_jsonb(a)
      || jsonb_build_object(
        'renter_name', p.full_name,
        'facility_name', f.name,
        'facility_building', f.building,
        'facility_room', f.room,
        'risk_summary', public.scoped_risk_summary(a.renter_id, a.admin_lane)
      ),
    'evidence', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'request_id', e.request_id,
        'occurrence_id', e.occurrence_id,
        'facility_id', e.facility_id,
        'facility_name', ef.name,
        'evidence_role', e.evidence_role,
        'observed_at', e.observed_at,
        'measured_value', e.measured_value,
        'request_title', rr.purpose,
        'starts_at', o.starts_at,
        'ends_at', o.ends_at
      ) order by e.observed_at desc)
      from public.reservation_anomaly_evidence e
      join public.facilities ef on ef.id = e.facility_id
      join public.reservation_requests rr on rr.id = e.request_id
      left join public.reservation_occurrences o on o.id = e.occurrence_id
      where e.anomaly_id = a.id
        and public.can_manage_reservation(e.request_id)
    ), '[]'::jsonb),
    'restricted_evidence_count', (
      select count(*)
      from public.reservation_anomaly_evidence e
      where e.anomaly_id = a.id
        and not public.can_manage_reservation(e.request_id)
    )
  ) into result_value
  from public.reservation_anomalies a
  join public.profiles p on p.id = a.renter_id
  join public.facilities f on f.id = a.facility_id
  where a.id = anomaly_row.id;

  return result_value;
end;
$$;

create or replace function public.transition_reservation_anomaly(
  p_anomaly_id uuid,
  p_action text,
  p_reason_code text default null,
  p_note text default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  anomaly_row public.reservation_anomalies%rowtype;
  target_status text;
  note_value text := nullif(trim(coalesce(p_note, '')), '');
  before_value jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into anomaly_row
  from public.reservation_anomalies
  where id = p_anomaly_id
  for update;
  if anomaly_row.id is null
     or public.admin_lane() <> anomaly_row.admin_lane
     or not public.can_manage_facility(anomaly_row.facility_id) then
    raise exception using errcode = '42501', message = 'Anomaly access denied';
  end if;

  target_status := case p_action
    when 'acknowledge' then 'acknowledged'
    when 'resolve' then 'resolved'
    when 'false_positive' then 'false_positive'
    else null
  end;
  if target_status is null then
    raise exception using errcode = '22023', message = 'Unknown anomaly action';
  end if;
  if p_action = 'false_positive' and p_reason_code = 'other' and note_value is null then
    raise exception using errcode = '22023', message = 'A note is required for other false-positive reasons';
  end if;

  before_value := jsonb_build_object('status', anomaly_row.status, 'resolution_code', anomaly_row.resolution_code);

  update public.reservation_anomalies
  set status = target_status,
      acknowledged_at = case when target_status = 'acknowledged' then now() else acknowledged_at end,
      acknowledged_by = case when target_status = 'acknowledged' then auth.uid() else acknowledged_by end,
      resolved_at = case when target_status in ('resolved', 'false_positive') then now() else resolved_at end,
      resolved_by = case when target_status in ('resolved', 'false_positive') then auth.uid() else resolved_by end,
      resolution_code = case when target_status in ('resolved', 'false_positive') then p_reason_code else resolution_code end,
      resolution_note = case when target_status in ('resolved', 'false_positive') then note_value else resolution_note end,
      effective_risk_points = case when target_status in ('resolved', 'false_positive') then 0 else effective_risk_points end,
      updated_at = now()
  where id = anomaly_row.id;

  perform public.log_anomaly_audit(
    anomaly_row.id,
    case target_status
      when 'acknowledged' then 'ANOMALY_ACKNOWLEDGED'
      when 'false_positive' then 'ANOMALY_FALSE_POSITIVE'
      else 'ANOMALY_RESOLVED'
    end,
    before_value,
    jsonb_build_object('status', target_status, 'resolution_code', p_reason_code),
    coalesce(note_value, p_reason_code),
    'admin',
    p_idempotency_key
  );

  perform public.recalculate_renter_risk_profiles(anomaly_row.renter_id, anomaly_row.admin_lane, now());
  return public.get_anomaly_detail(anomaly_row.id);
end;
$$;

create or replace function public.check_my_reservation_overlaps(
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_exclude_request_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if array_length(p_starts_at, 1) is distinct from array_length(p_ends_at, 1) then
    raise exception using errcode = '22023', message = 'Start and end arrays must match';
  end if;

  with requested as (
    select p_starts_at[i] as starts_at, p_ends_at[i] as ends_at
    from generate_subscripts(p_starts_at, 1) as i
    where p_starts_at[i] < p_ends_at[i]
  ), overlap_rows as (
    select distinct r.id as request_id, r.facility_name, o.starts_at, o.ends_at
    from requested req
    join public.reservation_requests r on r.requester_id = auth.uid()
      and (p_exclude_request_id is null or r.id <> p_exclude_request_id)
      and r.reservation_status in ('awaiting_payment', 'confirmed')
    join public.reservation_occurrences o on o.request_id = r.id
      and o.booking_state in ('held', 'booked')
      and o.starts_at < req.ends_at
      and req.starts_at < o.ends_at
      and extract(epoch from (least(o.ends_at, req.ends_at) - greatest(o.starts_at, req.starts_at))) >= 1800
  )
  select jsonb_build_object(
    'overlaps', coalesce(jsonb_agg(to_jsonb(overlap_rows) order by starts_at), '[]'::jsonb),
    'count', count(*)
  ) into result_value
  from overlap_rows;

  return result_value;
end;
$$;

revoke all on function public.scoped_risk_summary(uuid, text) from public, anon, authenticated;
revoke all on function public.get_anomaly_center(jsonb, jsonb, integer) from public, anon;
revoke all on function public.get_anomaly_detail(uuid) from public, anon;
revoke all on function public.get_reservation_risk_summary(uuid) from public, anon;
revoke all on function public.transition_reservation_anomaly(uuid, text, text, text, uuid) from public, anon;
revoke all on function public.check_my_reservation_overlaps(timestamptz[], timestamptz[], uuid) from public, anon;
grant execute on function public.get_anomaly_center(jsonb, jsonb, integer) to authenticated;
grant execute on function public.get_anomaly_detail(uuid) to authenticated;
grant execute on function public.get_reservation_risk_summary(uuid) to authenticated;
grant execute on function public.transition_reservation_anomaly(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.check_my_reservation_overlaps(timestamptz[], timestamptz[], uuid) to authenticated;

notify pgrst, 'reload schema';
