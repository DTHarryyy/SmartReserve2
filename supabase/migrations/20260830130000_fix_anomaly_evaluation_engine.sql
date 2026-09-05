-- The reservation-anomaly evaluation engine has never once completed
-- successfully: every queue-driven and nightly evaluation throws before
-- `renter_risk_profiles` can be written, which is why every renter shows
-- risk score 0 / "Not yet evaluated" and the "Reservation risk" card in the
-- admin UI is permanently stuck reporting an evaluation in progress.
--
-- Two independent runtime defects in 20260829130000_reservation_anomaly_engine.sql:
--   1. evaluate_excessive_reservation_creation used `count(distinct ...) over
--      ()`, which Postgres rejects unconditionally with
--      "DISTINCT is not implemented for window functions" (0A000). This fires
--      on every call regardless of data, before recalculate_renter_risk_profiles
--      ever runs.
--   2. upsert_reservation_anomaly called bare `digest(...)` under
--      `set search_path = public`, but digest() is a pgcrypto function that
--      lives in the `extensions` schema in this project (see
--      20260822110000_facility_rates_amenities_and_pricing.sql), so it fails
--      with "function digest(text, unknown) does not exist" (42883) the
--      moment any rule matches.
--
-- Because process_reservation_anomaly_queue runs each renter's evaluation
-- inside `exception when others` without ever deleting the queue row or
-- giving up, a poisoned evaluation retries forever (up to 60 min backoff)
-- and `evaluation_pending` (a bare `exists(row)` check) reads as "actively
-- updating" indefinitely.
--
-- This migration fixes both defects, adds a give-up threshold so a future
-- fault can never wedge the UI permanently, makes `evaluation_pending`
-- reflect whether an evaluation is actually imminent (adding a separate
-- `evaluation_stalled` signal for genuine backend faults), adds an
-- on-demand evaluation RPC so the admin UI's Refresh button doesn't have to
-- wait for the next cron tick, and backfills every renter who has never had
-- a risk profile computed.

-- 1a. Fix: DISTINCT inside a window function.
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
        count(*) over ()::integer as facility_count
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

-- 1b. Fix: unqualified digest() -> extensions.digest(), matching the
-- convention already used everywhere else in this codebase.
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
    extensions.digest(
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

revoke all on function public.evaluate_excessive_reservation_creation(uuid, text, timestamptz, boolean) from public, anon, authenticated;
revoke all on function public.upsert_reservation_anomaly(uuid, text, uuid, text, text, uuid[], uuid[], timestamptz, timestamptz, timestamptz, integer, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.evaluate_excessive_reservation_creation(uuid, text, timestamptz, boolean) to service_role;
grant execute on function public.upsert_reservation_anomaly(uuid, text, uuid, text, text, uuid[], uuid[], timestamptz, timestamptz, timestamptz, integer, jsonb, text, boolean) to service_role;

-- 2. Stop the queue from wedging forever: give up after 8 attempts instead
-- of retrying hourly indefinitely. The row is parked (not deleted) so
-- last_error stays visible for ops, and enqueue_reservation_anomaly_evaluation
-- already pulls next_attempt_at back to now() on any new activity, so this
-- is self-healing.
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
          next_attempt_at = case
            when attempt_count + 1 >= 8 then now() + interval '1 day'
            else now() + make_interval(mins => least(60, power(2, least(attempt_count + 1, 6))::integer))
          end
      where renter_id = item.renter_id and admin_lane = item.admin_lane;
      error_count := error_count + 1;
    end;
  end loop;

  return jsonb_build_object('processed', processed_count, 'errors', error_count);
end;
$$;

revoke all on function public.process_reservation_anomaly_queue(integer) from public, anon, authenticated;
grant execute on function public.process_reservation_anomaly_queue(integer) to service_role;

-- 3. Make evaluation_pending honest: only true when an evaluation is
-- actually imminent (due within 2 minutes), and add evaluation_stalled so a
-- genuinely stuck row (>= 3 failed attempts) surfaces as a fault rather
-- than an indefinite "updating" spinner. Also make the -infinity sentinel
-- explicit instead of relying on client-side date-parse behavior.
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

-- 4. On-demand evaluation RPC: lets the admin UI's Refresh button force an
-- immediate evaluation instead of waiting for the next pg_cron tick.
-- Mirrors the auth check and return shape of get_reservation_risk_summary
-- so the client can reuse the same RenterRiskSummary.fromJson deserializer.
create or replace function public.evaluate_reservation_risk_now(
  p_request_id uuid
) returns jsonb
language plpgsql
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

  perform public.evaluate_renter_anomalies(
    request_row.requester_id, request_row.admin_lane, now(), 'on_demand', true
  );
  delete from public.reservation_anomaly_evaluation_queue
  where renter_id = request_row.requester_id and admin_lane = request_row.admin_lane;

  return public.scoped_risk_summary(request_row.requester_id, request_row.admin_lane)
    || jsonb_build_object('request_id', request_row.id, 'facility_id', request_row.facility_id);
end;
$$;

revoke all on function public.evaluate_reservation_risk_now(uuid) from public, anon;
grant execute on function public.evaluate_reservation_risk_now(uuid) to authenticated;

-- 5. Backfill: no renter has ever had a risk profile computed because
-- every evaluation has thrown since this feature was introduced. Drain the
-- (now-fixable) stuck queue and run one nightly-style sweep so risk data
-- exists as soon as this migration lands, rather than admins waiting on the
-- next natural trigger per renter.
do $$
declare res jsonb; guard integer := 0;
begin
  update public.reservation_anomaly_evaluation_queue
  set next_attempt_at = now(), attempt_count = 0, last_error = null;

  loop
    res := public.process_reservation_anomaly_queue(200);
    guard := guard + 1;
    exit when coalesce((res->>'processed')::integer, 0) = 0 or guard > 50;
  end loop;
end $$;

select public.reevaluate_recent_renters(false);

notify pgrst, 'reload schema';
