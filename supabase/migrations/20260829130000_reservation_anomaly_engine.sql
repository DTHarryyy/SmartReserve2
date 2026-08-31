create or replace function public.anomaly_risk_level(p_score integer)
returns text
language sql
immutable
as $$
  select case
    when p_score >= 70 then 'critical'
    when p_score >= 50 then 'high'
    when p_score >= 30 then 'moderate'
    when p_score >= 15 then 'low'
    else 'normal'
  end;
$$;

create or replace function public.anomaly_decayed_points(
  p_points integer,
  p_last_contributing_at timestamptz,
  p_as_of timestamptz default now()
) returns integer
language sql
stable
as $$
  select greatest(0, least(100, round(
    coalesce(p_points, 0)::numeric
    * power(2::numeric, -greatest(0::numeric, extract(epoch from (coalesce(p_as_of, now()) - p_last_contributing_at)) / 86400 - 14) / 45)
  )::integer));
$$;

create or replace function public.payment_anomaly_eligible(p_request public.reservation_requests)
returns boolean
language sql
stable
as $$
  select p_request.admin_lane = 'external'
    and p_request.payment_exemption = 'none'
    and p_request.total_amount_centavos > 0
    and not p_request.legacy_financial_state;
$$;

create or replace function public.anomaly_rule_points(
  p_rule_key text,
  p_count integer
) returns integer
language sql
immutable
as $$
  select case
    when p_rule_key = 'repeated_no_show' and p_count >= 4 then 35
    when p_rule_key = 'repeated_no_show' and p_count >= 3 then 25
    when p_rule_key = 'overlapping_reservations' and p_count >= 2 then 20
    else case p_rule_key
      when 'consecutive_no_show_cluster' then 30
      when 'repeated_no_show' then 15
      when 'excessive_reservation_creation' then 10
      when 'facility_slot_hoarding' then 20
      when 'repeated_late_cancellation' then 18
      when 'reserve_cancel_reserve_cycle' then 15
      when 'overlapping_reservations' then 12
      when 'abnormal_duration' then 12
      when 'missed_down_payment' then 25
      when 'payment_deadline_expiration' then 18
      when 'full_payment_deadline_failure' then 20
      when 'payment_slot_blocking' then 20
      else 0
    end
  end;
$$;

create or replace function public.anomaly_severity_for_points(
  p_points integer,
  p_observe boolean default false
) returns text
language sql
immutable
as $$
  select case
    when p_observe then 'info'
    when p_points >= 35 then 'critical'
    when p_points >= 18 then 'high'
    when p_points >= 10 then 'moderate'
    when p_points > 0 then 'low'
    else 'info'
  end;
$$;

create or replace function public.anomaly_rule_title(p_rule_key text)
returns text
language sql
immutable
as $$
  select case p_rule_key
    when 'consecutive_no_show_cluster' then 'Consecutive no-show cluster'
    when 'repeated_no_show' then 'Repeated no-shows'
    when 'excessive_reservation_creation' then 'High reservation creation volume'
    when 'facility_slot_hoarding' then 'Facility slot hoarding signal'
    when 'repeated_late_cancellation' then 'Repeated late cancellations'
    when 'reserve_cancel_reserve_cycle' then 'Reserve-cancel-reserve cycle'
    when 'overlapping_reservations' then 'Overlapping reservations'
    when 'abnormal_duration' then 'Abnormal reservation duration'
    when 'missed_down_payment' then 'Missed down payment deadlines'
    when 'payment_deadline_expiration' then 'Repeated payment deadline expirations'
    when 'full_payment_deadline_failure' then 'Full payment deadline failures'
    when 'payment_slot_blocking' then 'Payment-based slot blocking signal'
    else initcap(replace(p_rule_key, '_', ' '))
  end;
$$;

create or replace function public.enqueue_reservation_anomaly_evaluation(
  p_renter_id uuid,
  p_admin_lane text,
  p_reason_keys text[] default '{}'
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_renter_id is null or p_admin_lane not in ('internal', 'external') then
    return;
  end if;

  insert into public.reservation_anomaly_evaluation_queue(
    renter_id, admin_lane, reason_keys, requested_at, next_attempt_at
  ) values (
    p_renter_id, p_admin_lane, coalesce(p_reason_keys, '{}'), now(), now()
  )
  on conflict (renter_id, admin_lane) do update
  set reason_keys = (
        select array(
          select distinct value
          from unnest(public.reservation_anomaly_evaluation_queue.reason_keys || excluded.reason_keys) as value
          where value is not null
          order by value
        )
      ),
      requested_at = now(),
      next_attempt_at = least(public.reservation_anomaly_evaluation_queue.next_attempt_at, now()),
      last_error = null;
end;
$$;

create or replace function public.refresh_facility_anomaly_baselines(
  p_facility_id uuid default null,
  p_as_of timestamptz default now()
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  changed_count integer := 0;
begin
  with eligible as (
    select
      o.facility_id,
      o.starts_at,
      extract(isodow from o.starts_at at time zone 'Asia/Manila')::integer as weekday,
      extract(hour from o.starts_at at time zone 'Asia/Manila')::integer as hour_bucket,
      greatest(1, extract(epoch from (o.ends_at - o.starts_at)) / 60)::numeric as minutes
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    where o.booking_state in ('booked', 'held')
      and o.lifecycle_stage in ('booked', 'checked_in', 'completed')
      and o.starts_at >= p_as_of - interval '180 days'
      and o.starts_at < p_as_of
      and (p_facility_id is null or o.facility_id = p_facility_id)
  ), facility_stats as (
    select
      facility_id,
      min(starts_at) as window_started_at,
      max(starts_at) as window_ended_at,
      count(*)::integer as sample_count,
      percentile_cont(0.5) within group (order by minutes) as p50,
      percentile_cont(0.9) within group (order by minutes) as p90
    from eligible
    group by facility_id
  ), prime as (
    select facility_id,
      jsonb_agg(
        jsonb_build_object('weekday', weekday, 'hour', hour_bucket, 'count', bucket_count)
        order by bucket_count desc, weekday, hour_bucket
      ) filter (where bucket_rank <= 6) as prime_slots
    from (
      select
        facility_id,
        weekday,
        hour_bucket,
        count(*)::integer as bucket_count,
        row_number() over (partition by facility_id order by count(*) desc, weekday, hour_bucket) as bucket_rank
      from eligible
      group by facility_id, weekday, hour_bucket
    ) ranked
    group by facility_id
  ), upserted as (
    insert into public.facility_anomaly_baselines(
      facility_id, window_started_at, window_ended_at, sample_count,
      duration_p50_minutes, duration_p90_minutes, prime_slots, calculated_at
    )
    select
      s.facility_id,
      coalesce(s.window_started_at, p_as_of - interval '180 days'),
      coalesce(s.window_ended_at, p_as_of),
      s.sample_count,
      s.p50,
      s.p90,
      coalesce(p.prime_slots, '[]'::jsonb),
      now()
    from facility_stats s
    left join prime p on p.facility_id = s.facility_id
    on conflict (facility_id) do update
    set window_started_at = excluded.window_started_at,
        window_ended_at = excluded.window_ended_at,
        sample_count = excluded.sample_count,
        duration_p50_minutes = excluded.duration_p50_minutes,
        duration_p90_minutes = excluded.duration_p90_minutes,
        prime_slots = excluded.prime_slots,
        calculated_at = now()
    returning 1
  )
  select count(*) into changed_count from upserted;
  return changed_count;
end;
$$;

create or replace function public.anomaly_is_prime_slot(
  p_facility_id uuid,
  p_starts_at timestamptz
) returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.facility_anomaly_baselines b
    cross join lateral jsonb_array_elements(b.prime_slots) slot
    where b.facility_id = p_facility_id
      and b.sample_count >= 30
      and (slot->>'weekday')::integer = extract(isodow from p_starts_at at time zone 'Asia/Manila')::integer
      and (slot->>'hour')::integer = extract(hour from p_starts_at at time zone 'Asia/Manila')::integer
  );
$$;

create or replace function public.log_anomaly_audit(
  p_anomaly_id uuid,
  p_event_key text,
  p_before jsonb default '{}'::jsonb,
  p_after jsonb default '{}'::jsonb,
  p_reason text default null,
  p_source text default 'realtime',
  p_idempotency_key uuid default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  anomaly_row public.reservation_anomalies%rowtype;
  actor public.profiles%rowtype;
begin
  select * into anomaly_row from public.reservation_anomalies where id = p_anomaly_id;
  if anomaly_row.id is null then
    return;
  end if;
  select * into actor from public.profiles where id = auth.uid();

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, details, material,
    source_type, source_id, created_at
  ) values (
    'anomaly',
    anomaly_row.id,
    anomaly_row.title,
    auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email, 'system'),
    coalesce(actor.role, 'system'),
    lower(replace(p_event_key, '_', ' ')),
    p_reason,
    coalesce(p_before, '{}'::jsonb),
    coalesce(p_after, '{}'::jsonb),
    jsonb_build_object(
      'event_key', p_event_key,
      'anomaly_id', anomaly_row.id,
      'renter_id', anomaly_row.renter_id,
      'admin_lane', anomaly_row.admin_lane,
      'facility_id', anomaly_row.facility_id,
      'rule_key', anomaly_row.rule_key,
      'rule_version', anomaly_row.rule_version,
      'evidence_count', (select count(*) from public.reservation_anomaly_evidence e where e.anomaly_id = anomaly_row.id),
      'source', coalesce(p_source, 'realtime'),
      'idempotency_key', p_idempotency_key
    ),
    true,
    'reservation_anomaly:' || p_event_key,
    coalesce(p_idempotency_key, gen_random_uuid()),
    now()
  ) on conflict (source_type, source_id) do nothing;
end;
$$;

create or replace function public.notify_anomaly_admins(
  p_anomaly_id uuid,
  p_tier text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  anomaly_row public.reservation_anomalies%rowtype;
  sent_count integer := 0;
begin
  if p_tier not in ('high', 'critical') then
    return 0;
  end if;
  select * into anomaly_row from public.reservation_anomalies where id = p_anomaly_id;
  if anomaly_row.id is null or anomaly_row.detection_mode <> 'active' then
    return 0;
  end if;

  insert into public.app_notifications(recipient_id, anomaly_id, kind, title, body)
  select
    p.id,
    anomaly_row.id,
    case when p_tier = 'critical' then 'anomaly_critical' else 'anomaly_high' end,
    case when p_tier = 'critical' then 'Critical risk signal' else 'High risk signal' end,
    anomaly_row.title || ' at ' || coalesce(f.name, 'an assigned facility') || '. ' || anomaly_row.explanation
  from public.facility_admin_assignments a
  join public.profiles p on p.id = a.admin_id
  left join public.facilities f on f.id = anomaly_row.facility_id
  where a.facility_id = anomaly_row.facility_id
    and p.account_status = 'active'
    and public.admin_lane(p.id) = anomaly_row.admin_lane
  on conflict do nothing;

  get diagnostics sent_count = row_count;
  return sent_count;
end;
$$;

create or replace function public.upsert_reservation_anomaly(
  p_renter_id uuid,
  p_admin_lane text,
  p_facility_id uuid,
  p_rule_key text,
  p_correlation_key text,
  p_evidence_request_ids uuid[],
  p_evidence_occurrence_ids uuid[] default '{}',
  p_last_contributing_at timestamptz default now(),
  p_window_started_at timestamptz default now(),
  p_window_ended_at timestamptz default now(),
  p_count integer default 1,
  p_evidence_summary jsonb default '{}'::jsonb,
  p_explanation text default null,
  p_notify boolean default true
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  rule_row public.anomaly_rules%rowtype;
  v_anomaly_id uuid;
  fingerprint text;
  points integer;
  effective integer;
  severity_value text;
  req_id uuid;
  occ_id uuid;
  idx integer;
  old_status text;
  old_severity text;
begin
  select * into rule_row
  from public.anomaly_rules
  where rule_key = p_rule_key
    and enabled
    and p_admin_lane = any(applicable_lanes);
  if rule_row.rule_key is null then
    return null;
  end if;

  points := public.anomaly_rule_points(p_rule_key, coalesce(p_count, 1));
  effective := case when rule_row.mode = 'observe' then 0 else points end;
  severity_value := public.anomaly_severity_for_points(points, rule_row.mode = 'observe');
  fingerprint := encode(
    digest(
      p_rule_key || ':' || p_facility_id::text || ':' ||
      array_to_string(coalesce(p_evidence_request_ids, '{}'), ',') || ':' ||
      array_to_string(coalesce(p_evidence_occurrence_ids, '{}'), ','),
      'sha256'
    ),
    'hex'
  );

  select id, status, severity into v_anomaly_id, old_status, old_severity
  from public.reservation_anomalies
  where renter_id = p_renter_id
    and admin_lane = p_admin_lane
    and rule_key = p_rule_key
    and facility_id = p_facility_id
    and status in ('open', 'acknowledged')
  for update;

  if v_anomaly_id is null then
    insert into public.reservation_anomalies(
      renter_id, admin_lane, facility_id, rule_key, correlation_key,
      evidence_fingerprint, detection_mode, severity, base_risk_points,
      effective_risk_points, title, explanation, evidence_summary,
      window_started_at, window_ended_at, last_contributing_at, status,
      rule_version, first_detected_at, last_detected_at, last_evaluated_at
    ) values (
      p_renter_id, p_admin_lane, p_facility_id, p_rule_key, p_correlation_key,
      fingerprint, rule_row.mode, severity_value, points, effective,
      public.anomaly_rule_title(p_rule_key),
      coalesce(p_explanation, public.anomaly_rule_title(p_rule_key) || ' matched the configured threshold.'),
      coalesce(p_evidence_summary, '{}'::jsonb),
      p_window_started_at, p_window_ended_at, p_last_contributing_at, 'open',
      rule_row.rule_version, now(), now(), now()
    )
    returning id into v_anomaly_id;
    perform public.log_anomaly_audit(v_anomaly_id, 'ANOMALY_DETECTED', '{}'::jsonb, jsonb_build_object('severity', severity_value, 'points', effective), null, 'realtime');
  else
    update public.reservation_anomalies
    set correlation_key = p_correlation_key,
        evidence_fingerprint = fingerprint,
        detection_mode = rule_row.mode,
        severity = severity_value,
        base_risk_points = points,
        effective_risk_points = effective,
        explanation = coalesce(p_explanation, explanation),
        evidence_summary = coalesce(p_evidence_summary, evidence_summary),
        window_started_at = p_window_started_at,
        window_ended_at = p_window_ended_at,
        last_contributing_at = p_last_contributing_at,
        rule_version = rule_row.rule_version,
        last_detected_at = now(),
        last_evaluated_at = now(),
        updated_at = now()
    where id = v_anomaly_id;
    if old_severity is distinct from severity_value then
      perform public.log_anomaly_audit(v_anomaly_id, 'ANOMALY_UPDATED', jsonb_build_object('severity', old_severity), jsonb_build_object('severity', severity_value), null, 'realtime');
    end if;
  end if;

  delete from public.reservation_anomaly_evidence e where e.anomaly_id = v_anomaly_id;
  for idx in 1..coalesce(array_length(p_evidence_request_ids, 1), 0) loop
    req_id := p_evidence_request_ids[idx];
    occ_id := null;
    if coalesce(array_length(p_evidence_occurrence_ids, 1), 0) >= idx then
      occ_id := p_evidence_occurrence_ids[idx];
    end if;
    insert into public.reservation_anomaly_evidence(
      anomaly_id, request_id, occurrence_id, facility_id, evidence_role, observed_at, measured_value
    )
    select
      v_anomaly_id,
      req_id,
      occ_id,
      p_facility_id,
      p_rule_key,
      coalesce(
        (select o.starts_at from public.reservation_occurrences o where o.id = occ_id),
        (select r.created_at from public.reservation_requests r where r.id = req_id),
        p_last_contributing_at
      ),
      p_count
    on conflict do nothing;
  end loop;

  if p_notify and rule_row.mode = 'active' and severity_value in ('high', 'critical') then
    perform public.notify_anomaly_admins(v_anomaly_id, severity_value);
  end if;

  return v_anomaly_id;
end;
$$;

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
      no_show_occurrences_30d, cancelled_occurrences_30d, late_cancellations_30d,
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

create or replace function public.evaluate_repeated_no_show(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  row record;
  anomaly_id uuid;
  matched_count integer := 0;
begin
  for row in
    select
      o.facility_id,
      count(*)::integer as evidence_count,
      array_agg(r.id order by o.starts_at desc) as request_ids,
      array_agg(o.id order by o.starts_at desc) as occurrence_ids,
      min(o.starts_at) as window_start,
      max(o.starts_at) as last_at
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    where r.requester_id = p_renter_id
      and r.admin_lane = p_admin_lane
      and o.lifecycle_stage = 'no_show'
      and o.booking_state = 'booked'
      and coalesce(o.attendance_marked_at, o.starts_at) >= p_as_of - interval '30 days'
      and o.starts_at <= p_as_of
    group by o.facility_id
    having count(*) >= 2
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'repeated_no_show',
      'repeated_no_show:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('count', row.evidence_count, 'threshold', 2, 'window_days', 30),
      row.evidence_count || ' no-show outcomes were recorded in the last 30 days.',
      p_notify
    );
    if anomaly_id is not null then
      insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing;
      matched_count := matched_count + 1;
    end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_consecutive_no_show_cluster(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  row record;
  anomaly_id uuid;
  matched_count integer := 0;
begin
  for row in
    with base as (
      select
        o.facility_id,
        r.id as request_id,
        o.id as occurrence_id,
        o.starts_at,
        (o.starts_at at time zone 'Asia/Manila')::date as local_date
      from public.reservation_occurrences o
      join public.reservation_requests r on r.id = o.request_id
      where r.requester_id = p_renter_id
        and r.admin_lane = p_admin_lane
        and o.lifecycle_stage = 'no_show'
        and o.booking_state = 'booked'
        and coalesce(o.attendance_marked_at, o.starts_at) >= p_as_of - interval '7 days'
        and o.starts_at <= p_as_of
    ), grouped as (
      select
        facility_id,
        count(*)::integer as evidence_count,
        max(starts_at) - min(starts_at) as span,
        count(distinct local_date)::integer as distinct_days,
        max(local_date) - min(local_date) as day_span,
        array_agg(request_id order by starts_at desc) as request_ids,
        array_agg(occurrence_id order by starts_at desc) as occurrence_ids,
        min(starts_at) as window_start,
        max(starts_at) as last_at
      from base
      group by facility_id
    )
    select *
    from grouped
    where evidence_count >= 3
      and (span <= interval '72 hours' or (distinct_days >= 3 and day_span = 2))
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'consecutive_no_show_cluster',
      'consecutive_no_show_cluster:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('count', row.evidence_count, 'threshold', 3, 'window_days', 7),
      'Three or more close no-show outcomes were recorded in a short window.',
      p_notify
    );
    if anomaly_id is not null then
      insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing;
      matched_count := matched_count + 1;
    end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_excessive_reservation_creation(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  for row in
    with base as (
      select facility_id, id, created_at
      from public.reservation_requests
      where requester_id = p_renter_id
        and admin_lane = p_admin_lane
        and created_at >= p_as_of - interval '7 days'
        and created_at <= p_as_of
    ), grouped as (
      select
        facility_id,
        count(*)::integer as count_7d,
        count(*) filter (where created_at >= p_as_of - interval '24 hours')::integer as count_24h,
        array_agg(id order by created_at desc) as request_ids,
        min(created_at) as window_start,
        max(created_at) as last_at,
        count(distinct facility_id) over ()::integer as facility_count
      from base
      group by facility_id
    )
    select * from grouped where count_24h >= 6 or count_7d >= 12
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'excessive_reservation_creation',
      'excessive_reservation_creation:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, '{}', row.last_at, row.window_start, p_as_of,
      greatest(row.count_24h, row.count_7d),
      jsonb_build_object('requests_24h', row.count_24h, 'threshold_24h', 6, 'requests_7d', row.count_7d, 'threshold_7d', 12, 'facility_count', row.facility_count),
      'Reservation creation volume reached a configured calibration threshold.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_repeated_late_cancellation(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  for row in
    select
      o.facility_id,
      count(*)::integer as evidence_count,
      array_agg(r.id order by o.cancelled_at desc) as request_ids,
      array_agg(o.id order by o.cancelled_at desc) as occurrence_ids,
      min(o.cancelled_at) as window_start,
      max(o.cancelled_at) as last_at
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    where r.requester_id = p_renter_id
      and r.admin_lane = p_admin_lane
      and o.cancelled_at >= p_as_of - interval '30 days'
      and o.cancelled_at > o.starts_at - interval '12 hours'
    group by o.facility_id
    having count(*) >= 3
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'repeated_late_cancellation',
      'repeated_late_cancellation:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('count', row.evidence_count, 'threshold', 3, 'lead_hours', 12, 'window_days', 30),
      row.evidence_count || ' cancellations were recorded less than 12 hours before start.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_reserve_cancel_reserve_cycle(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  for row in
    with cycles as (
      select
        c.facility_id,
        c.request_id as cancelled_request_id,
        n.id as new_request_id,
        c.cancelled_at
      from public.reservation_occurrences c
      join public.reservation_requests cr on cr.id = c.request_id
      join public.reservation_requests n on n.requester_id = cr.requester_id
        and n.admin_lane = cr.admin_lane
        and n.facility_id = c.facility_id
        and n.id <> cr.id
        and n.created_at > c.cancelled_at
        and n.created_at <= c.cancelled_at + interval '72 hours'
      where cr.requester_id = p_renter_id
        and cr.admin_lane = p_admin_lane
        and c.cancelled_at >= p_as_of - interval '30 days'
    )
    select
      facility_id,
      count(*)::integer as evidence_count,
      array_agg(distinct cancelled_request_id) || array_agg(distinct new_request_id) as request_ids,
      min(cancelled_at) as window_start,
      max(cancelled_at) as last_at
    from cycles
    group by facility_id
    having count(*) >= 3
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'reserve_cancel_reserve_cycle',
      'reserve_cancel_reserve_cycle:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, '{}', row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('cycles', row.evidence_count, 'threshold', 3, 'new_request_hours', 72),
      'Cancellation followed by a new request repeated within 72 hours.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_overlapping_reservations(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  for row in
    with eligible as (
      select r.id as request_id, o.id as occurrence_id, o.facility_id, o.starts_at, o.ends_at
      from public.reservation_requests r
      join public.reservation_occurrences o on o.request_id = r.id
      where r.requester_id = p_renter_id
        and r.admin_lane = p_admin_lane
        and r.reservation_status in ('awaiting_payment', 'confirmed')
        and o.booking_state in ('held', 'booked')
        and o.starts_at >= p_as_of - interval '30 days'
        and o.starts_at <= p_as_of + interval '180 days'
    ), pairs as (
      select
        e1.facility_id,
        e1.request_id as request_id_1,
        e2.request_id as request_id_2,
        e1.occurrence_id as occurrence_id_1,
        e2.occurrence_id as occurrence_id_2,
        greatest(e1.starts_at, e2.starts_at) as overlap_start,
        least(e1.ends_at, e2.ends_at) as overlap_end
      from eligible e1
      join eligible e2 on e1.occurrence_id < e2.occurrence_id
        and e1.starts_at < e2.ends_at
        and e2.starts_at < e1.ends_at
        and extract(epoch from (least(e1.ends_at, e2.ends_at) - greatest(e1.starts_at, e2.starts_at))) >= 1800
    ), projected as (
      select facility_id, request_id_1, request_id_2, occurrence_id_1, occurrence_id_2, overlap_start
      from pairs
      union all
      select e2.facility_id, p.request_id_1, p.request_id_2, p.occurrence_id_1, p.occurrence_id_2, p.overlap_start
      from pairs p
      join eligible e2 on e2.occurrence_id = p.occurrence_id_2
      where e2.facility_id <> p.facility_id
    )
    select
      facility_id,
      count(*)::integer as evidence_count,
      array_agg(distinct request_id_1) || array_agg(distinct request_id_2) as request_ids,
      array_agg(distinct occurrence_id_1) || array_agg(distinct occurrence_id_2) as occurrence_ids,
      min(overlap_start) as window_start,
      max(overlap_start) as last_at
    from projected
    group by facility_id
    having count(*) >= 1
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'overlapping_reservations',
      'overlapping_reservations:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('overlap_pairs', row.evidence_count, 'minimum_minutes', 30, 'window_days', 30),
      'Approved or held reservations overlap by at least 30 minutes.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_payment_anomaly(
  p_renter_id uuid,
  p_admin_lane text,
  p_rule_key text,
  p_reason_codes text[],
  p_threshold integer,
  p_window interval,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  if p_admin_lane <> 'external' then
    return 0;
  end if;
  for row in
    select
      r.facility_id,
      count(*)::integer as evidence_count,
      array_agg(r.id order by r.terminal_at desc) as request_ids,
      min(r.terminal_at) as window_start,
      max(r.terminal_at) as last_at
    from public.reservation_requests r
    where r.requester_id = p_renter_id
      and r.admin_lane = 'external'
      and public.payment_anomaly_eligible(r)
      and r.terminal_reason_code = any(p_reason_codes)
      and r.terminal_at >= p_as_of - p_window
      and r.terminal_at <= p_as_of
    group by r.facility_id
    having count(*) >= p_threshold
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, p_rule_key,
      p_rule_key || ':' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, '{}', row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('count', row.evidence_count, 'threshold', p_threshold, 'terminal_reason_codes', p_reason_codes),
      row.evidence_count || ' payment deadline expirations matched this rule.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_missed_down_payment(p_renter_id uuid, p_admin_lane text, p_as_of timestamptz default now(), p_notify boolean default true)
returns integer language sql security definer set search_path = public as $$
  select public.evaluate_payment_anomaly(p_renter_id, p_admin_lane, 'missed_down_payment', array['down_payment_deadline'], 3, interval '30 days', p_as_of, p_notify);
$$;

create or replace function public.evaluate_payment_deadline_expiration(p_renter_id uuid, p_admin_lane text, p_as_of timestamptz default now(), p_notify boolean default true)
returns integer language sql security definer set search_path = public as $$
  select public.evaluate_payment_anomaly(p_renter_id, p_admin_lane, 'payment_deadline_expiration', array['down_payment_deadline','balance_payment_deadline'], 3, interval '60 days', p_as_of, p_notify);
$$;

create or replace function public.evaluate_full_payment_deadline_failure(p_renter_id uuid, p_admin_lane text, p_as_of timestamptz default now(), p_notify boolean default true)
returns integer language sql security definer set search_path = public as $$
  select public.evaluate_payment_anomaly(p_renter_id, p_admin_lane, 'full_payment_deadline_failure', array['balance_payment_deadline'], 2, interval '60 days', p_as_of, p_notify);
$$;

create or replace function public.evaluate_abnormal_duration(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  for row in
    select
      o.facility_id,
      count(*)::integer as evidence_count,
      array_agg(r.id order by o.starts_at desc) as request_ids,
      array_agg(o.id order by o.starts_at desc) as occurrence_ids,
      min(o.starts_at) as window_start,
      max(o.starts_at) as last_at,
      max(greatest(b.duration_p90_minutes, b.duration_p50_minutes * 1.5)) as threshold_minutes
    from public.reservation_occurrences o
    join public.reservation_requests r on r.id = o.request_id
    join public.facility_anomaly_baselines b on b.facility_id = o.facility_id and b.sample_count >= 30
    where r.requester_id = p_renter_id
      and r.admin_lane = p_admin_lane
      and o.starts_at >= p_as_of - interval '60 days'
      and extract(epoch from (o.ends_at - o.starts_at)) / 60 >= greatest(b.duration_p90_minutes, b.duration_p50_minutes * 1.5)
    group by o.facility_id
    having count(*) >= 2
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'abnormal_duration',
      'abnormal_duration:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('count', row.evidence_count, 'threshold_count', 2, 'threshold_minutes', row.threshold_minutes, 'window_days', 60),
      'Reservation durations exceeded this facility baseline more than once.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_facility_slot_hoarding(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  for row in
    with adverse as (
      select o.facility_id, r.id as request_id, o.id as occurrence_id, o.starts_at, o.ends_at
      from public.reservation_occurrences o
      join public.reservation_requests r on r.id = o.request_id
      join public.facility_anomaly_baselines b on b.facility_id = o.facility_id and b.sample_count >= 30
      where r.requester_id = p_renter_id
        and r.admin_lane = p_admin_lane
        and o.starts_at >= p_as_of - interval '30 days'
        and public.anomaly_is_prime_slot(o.facility_id, o.starts_at)
        and (
          o.lifecycle_stage = 'no_show'
          or o.cancelled_at is not null
          or r.terminal_reason_code in ('down_payment_deadline', 'balance_payment_deadline')
        )
    ), totals as (
      select
        r.facility_id,
        count(*)::integer as total_count
      from public.reservation_occurrences o
      join public.reservation_requests r on r.id = o.request_id
      where r.requester_id = p_renter_id
        and r.admin_lane = p_admin_lane
        and o.starts_at >= p_as_of - interval '30 days'
        and public.anomaly_is_prime_slot(o.facility_id, o.starts_at)
      group by r.facility_id
    )
    select
      a.facility_id,
      count(*)::integer as evidence_count,
      array_agg(a.request_id order by a.starts_at desc) as request_ids,
      array_agg(a.occurrence_id order by a.starts_at desc) as occurrence_ids,
      sum(extract(epoch from (a.ends_at - a.starts_at)) / 3600) as blocked_hours,
      count(*)::numeric / greatest(max(t.total_count), 1) as adverse_ratio,
      min(a.starts_at) as window_start,
      max(a.starts_at) as last_at
    from adverse a
    join totals t on t.facility_id = a.facility_id
    group by a.facility_id
    having count(*) >= 3
      and sum(extract(epoch from (a.ends_at - a.starts_at)) / 3600) >= 6
      and count(*)::numeric / greatest(max(t.total_count), 1) >= 0.6
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'facility_slot_hoarding',
      'facility_slot_hoarding:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('adverse_prime_occurrences', row.evidence_count, 'blocked_hours', row.blocked_hours, 'adverse_ratio', row.adverse_ratio, 'window_days', 30),
      'Prime-slot adverse outcomes reached the facility baseline threshold.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_payment_slot_blocking(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare row record; anomaly_id uuid; matched_count integer := 0;
begin
  if p_admin_lane <> 'external' then return 0; end if;
  for row in
    select
      o.facility_id,
      count(*)::integer as evidence_count,
      array_agg(r.id order by r.terminal_at desc) as request_ids,
      array_agg(o.id order by r.terminal_at desc) as occurrence_ids,
      sum(extract(epoch from (o.ends_at - o.starts_at)) / 3600) as blocked_hours,
      min(r.terminal_at) as window_start,
      max(r.terminal_at) as last_at
    from public.reservation_requests r
    join public.reservation_occurrences o on o.request_id = r.id
    join public.facility_anomaly_baselines b on b.facility_id = o.facility_id and b.sample_count >= 30
    where r.requester_id = p_renter_id
      and r.admin_lane = 'external'
      and public.payment_anomaly_eligible(r)
      and r.terminal_reason_code in ('down_payment_deadline', 'balance_payment_deadline')
      and r.terminal_at >= p_as_of - interval '60 days'
      and public.anomaly_is_prime_slot(o.facility_id, o.starts_at)
    group by o.facility_id
    having count(*) >= 3
      and sum(extract(epoch from (o.ends_at - o.starts_at)) / 3600) >= 6
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id, p_admin_lane, row.facility_id, 'payment_slot_blocking',
      'payment_slot_blocking:' || p_renter_id::text || ':' || p_admin_lane,
      row.request_ids, row.occurrence_ids, row.last_at, row.window_start, p_as_of,
      row.evidence_count,
      jsonb_build_object('prime_payment_expirations', row.evidence_count, 'blocked_hours', row.blocked_hours, 'window_days', 60),
      'Payment expirations repeatedly held prime slots for this facility.',
      p_notify
    );
    if anomaly_id is not null then insert into pg_temp._matched_anomalies values (anomaly_id) on conflict do nothing; matched_count := matched_count + 1; end if;
  end loop;
  return matched_count;
end;
$$;

create or replace function public.evaluate_renter_anomalies(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_source text default 'realtime',
  p_notify boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  matched integer := 0;
  resolved_count integer := 0;
begin
  if p_renter_id is null or p_admin_lane not in ('internal', 'external') then
    return jsonb_build_object('matched', 0, 'resolved', 0);
  end if;

  create temporary table if not exists _matched_anomalies(id uuid primary key) on commit drop;
  truncate table _matched_anomalies;

  matched := matched + public.evaluate_consecutive_no_show_cluster(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_repeated_no_show(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_excessive_reservation_creation(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_facility_slot_hoarding(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_repeated_late_cancellation(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_reserve_cancel_reserve_cycle(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_overlapping_reservations(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_abnormal_duration(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_missed_down_payment(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_payment_deadline_expiration(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_full_payment_deadline_failure(p_renter_id, p_admin_lane, p_as_of, p_notify);
  matched := matched + public.evaluate_payment_slot_blocking(p_renter_id, p_admin_lane, p_as_of, p_notify);

  update public.reservation_anomalies a
  set status = 'resolved',
      resolved_at = now(),
      resolved_by = null,
      resolution_code = 'window_cleared',
      resolution_note = 'The rolling-window threshold is no longer met.',
      effective_risk_points = 0,
      last_evaluated_at = now(),
      updated_at = now()
  where a.renter_id = p_renter_id
    and a.admin_lane = p_admin_lane
    and a.status in ('open', 'acknowledged')
    and a.detection_mode = 'active'
    and not exists (select 1 from _matched_anomalies m where m.id = a.id);
  get diagnostics resolved_count = row_count;

  update public.reservation_anomalies a
  set effective_risk_points = case
        when detection_mode = 'active' and status in ('open', 'acknowledged')
          then public.anomaly_decayed_points(base_risk_points, last_contributing_at, p_as_of)
        else 0
      end,
      last_evaluated_at = now(),
      updated_at = now()
  where a.renter_id = p_renter_id
    and a.admin_lane = p_admin_lane;

  perform public.recalculate_renter_risk_profiles(p_renter_id, p_admin_lane, p_as_of);

  return jsonb_build_object('matched', matched, 'resolved', resolved_count, 'source', coalesce(p_source, 'realtime'));
end;
$$;

create or replace function public.process_reservation_anomaly_queue(
  p_limit integer default 50
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  processed_count integer := 0;
  error_count integer := 0;
begin
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid queue limit';
  end if;

  for item in
    select *
    from public.reservation_anomaly_evaluation_queue
    where next_attempt_at <= now()
    order by requested_at
    limit p_limit
    for update skip locked
  loop
    begin
      perform public.evaluate_renter_anomalies(item.renter_id, item.admin_lane, now(), 'queue', true);
      delete from public.reservation_anomaly_evaluation_queue
      where renter_id = item.renter_id and admin_lane = item.admin_lane;
      processed_count := processed_count + 1;
    exception when others then
      update public.reservation_anomaly_evaluation_queue
      set attempt_count = attempt_count + 1,
          last_error = sqlerrm,
          next_attempt_at = now() + make_interval(mins => least(60, power(2, least(attempt_count + 1, 6))::integer))
      where renter_id = item.renter_id and admin_lane = item.admin_lane;
      error_count := error_count + 1;
    end;
  end loop;

  return jsonb_build_object('processed', processed_count, 'errors', error_count);
end;
$$;

create or replace function public.reevaluate_recent_renters(
  p_notify boolean default false
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  row record;
  processed integer := 0;
begin
  perform public.refresh_facility_anomaly_baselines(null, now());
  for row in
    select distinct requester_id as renter_id, admin_lane
    from public.reservation_requests
    where created_at >= now() - interval '180 days'
    union
    select distinct renter_id, admin_lane
    from public.reservation_anomalies
    where status in ('open', 'acknowledged')
  loop
    perform public.evaluate_renter_anomalies(row.renter_id, row.admin_lane, now(), 'nightly', p_notify);
    processed := processed + 1;
  end loop;
  return processed;
end;
$$;

create extension if not exists pg_cron;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'smartreserve-anomaly-queue') then
    perform cron.schedule(
      'smartreserve-anomaly-queue',
      '* * * * *',
      'select public.process_reservation_anomaly_queue(50);'
    );
  end if;
  if not exists (select 1 from cron.job where jobname = 'smartreserve-anomaly-nightly') then
    perform cron.schedule(
      'smartreserve-anomaly-nightly',
      '12 18 * * *',
      'select public.reevaluate_recent_renters(false);'
    );
  end if;
end $$;

revoke all on function public.enqueue_reservation_anomaly_evaluation(uuid, text, text[]) from public, anon, authenticated;
revoke all on function public.process_reservation_anomaly_queue(integer) from public, anon, authenticated;
revoke all on function public.evaluate_renter_anomalies(uuid, text, timestamptz, text, boolean) from public, anon, authenticated;
revoke all on function public.recalculate_renter_risk_profiles(uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function public.refresh_facility_anomaly_baselines(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.reevaluate_recent_renters(boolean) from public, anon, authenticated;
revoke all on function public.upsert_reservation_anomaly(uuid, text, uuid, text, text, uuid[], uuid[], timestamptz, timestamptz, timestamptz, integer, jsonb, text, boolean) from public, anon, authenticated;
revoke all on function public.log_anomaly_audit(uuid, text, jsonb, jsonb, text, text, uuid) from public, anon, authenticated;
revoke all on function public.notify_anomaly_admins(uuid, text) from public, anon, authenticated;
revoke all on function public.evaluate_repeated_no_show(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_consecutive_no_show_cluster(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_excessive_reservation_creation(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_repeated_late_cancellation(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_reserve_cancel_reserve_cycle(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_overlapping_reservations(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_payment_anomaly(uuid, text, text, text[], integer, interval, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_missed_down_payment(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_payment_deadline_expiration(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_full_payment_deadline_failure(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_abnormal_duration(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_facility_slot_hoarding(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.evaluate_payment_slot_blocking(uuid, text, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.process_reservation_anomaly_queue(integer) to service_role;
grant execute on function public.evaluate_renter_anomalies(uuid, text, timestamptz, text, boolean) to service_role;
grant execute on function public.recalculate_renter_risk_profiles(uuid, text, timestamptz) to service_role;
grant execute on function public.refresh_facility_anomaly_baselines(uuid, timestamptz) to service_role;
grant execute on function public.reevaluate_recent_renters(boolean) to service_role;
grant execute on function public.upsert_reservation_anomaly(uuid, text, uuid, text, text, uuid[], uuid[], timestamptz, timestamptz, timestamptz, integer, jsonb, text, boolean) to service_role;
grant execute on function public.log_anomaly_audit(uuid, text, jsonb, jsonb, text, text, uuid) to service_role;
grant execute on function public.notify_anomaly_admins(uuid, text) to service_role;
grant execute on function public.evaluate_repeated_no_show(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_consecutive_no_show_cluster(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_excessive_reservation_creation(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_repeated_late_cancellation(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_reserve_cancel_reserve_cycle(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_overlapping_reservations(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_payment_anomaly(uuid, text, text, text[], integer, interval, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_missed_down_payment(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_payment_deadline_expiration(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_full_payment_deadline_failure(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_abnormal_duration(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_facility_slot_hoarding(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.evaluate_payment_slot_blocking(uuid, text, timestamptz, boolean) to service_role;

notify pgrst, 'reload schema';
