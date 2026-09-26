create or replace function public.anomaly_rule_config_is_valid(
  p_rule_key text,
  p_configuration jsonb
) returns boolean
language plpgsql
immutable
as $$
begin
  if p_configuration is null or jsonb_typeof(p_configuration) <> 'object' then
    return false;
  end if;
  if p_rule_key is null or length(trim(p_rule_key)) = 0 then
    return false;
  end if;
  return true;
end;
$$;

create table if not exists public.anomaly_rules (
  rule_key text primary key,
  enabled boolean not null default true,
  mode text not null default 'active' check (mode in ('active', 'observe')),
  applicable_lanes text[] not null default array['internal', 'external'],
  signal_family text not null,
  base_weight smallint not null check (base_weight between 0 and 100),
  evaluation_window_hours integer not null check (evaluation_window_hours between 1 and 4320),
  configuration jsonb not null default '{}'::jsonb,
  rule_version integer not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null,
  constraint anomaly_rules_lanes_check
    check (applicable_lanes <@ array['internal', 'external']::text[]),
  constraint anomaly_rules_configuration_check
    check (public.anomaly_rule_config_is_valid(rule_key, configuration))
);

create table if not exists public.facility_anomaly_baselines (
  facility_id uuid primary key references public.facilities(id) on delete cascade,
  window_started_at timestamptz not null,
  window_ended_at timestamptz not null,
  sample_count integer not null default 0 check (sample_count >= 0),
  duration_p50_minutes numeric,
  duration_p90_minutes numeric,
  prime_slots jsonb not null default '[]'::jsonb,
  calculated_at timestamptz not null default now()
);

create table if not exists public.reservation_anomalies (
  id uuid primary key default gen_random_uuid(),
  renter_id uuid not null references public.profiles(id) on delete cascade,
  admin_lane text not null check (admin_lane in ('internal', 'external')),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  rule_key text not null references public.anomaly_rules(rule_key),
  correlation_key text not null,
  evidence_fingerprint text not null,
  detection_mode text not null check (detection_mode in ('active', 'observe')),
  severity text not null check (severity in ('info', 'low', 'moderate', 'high', 'critical')),
  base_risk_points smallint not null default 0 check (base_risk_points between 0 and 100),
  effective_risk_points smallint not null default 0 check (effective_risk_points between 0 and 100),
  title text not null,
  explanation text not null,
  evidence_summary jsonb not null default '{}'::jsonb,
  window_started_at timestamptz not null,
  window_ended_at timestamptz not null,
  last_contributing_at timestamptz not null,
  status text not null default 'open' check (status in ('open', 'acknowledged', 'resolved', 'false_positive')),
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles(id) on delete set null,
  resolved_at timestamptz,
  resolved_by uuid references public.profiles(id) on delete set null,
  resolution_code text,
  resolution_note text,
  rule_version integer not null default 1,
  first_detected_at timestamptz not null default now(),
  last_detected_at timestamptz not null default now(),
  last_evaluated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists reservation_anomalies_open_unique_idx
  on public.reservation_anomalies(renter_id, admin_lane, rule_key, facility_id)
  where status in ('open', 'acknowledged');

create index if not exists reservation_anomalies_center_idx
  on public.reservation_anomalies(admin_lane, facility_id, status, severity, last_detected_at desc);
create index if not exists reservation_anomalies_renter_idx
  on public.reservation_anomalies(renter_id, admin_lane, status);
create index if not exists reservation_anomalies_correlation_idx
  on public.reservation_anomalies(correlation_key);
create index if not exists reservation_anomalies_rule_idx
  on public.reservation_anomalies(rule_key, status, last_evaluated_at);

create table if not exists public.reservation_anomaly_evidence (
  id uuid primary key default gen_random_uuid(),
  anomaly_id uuid not null references public.reservation_anomalies(id) on delete cascade,
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  occurrence_id uuid references public.reservation_occurrences(id) on delete cascade,
  facility_id uuid not null references public.facilities(id) on delete cascade,
  evidence_role text not null,
  observed_at timestamptz not null,
  measured_value numeric,
  created_at timestamptz not null default now()
);

create unique index if not exists reservation_anomaly_evidence_unique_idx
  on public.reservation_anomaly_evidence(
    anomaly_id,
    request_id,
    coalesce(occurrence_id, '00000000-0000-0000-0000-000000000000'::uuid),
    evidence_role
  );

create index if not exists reservation_anomaly_evidence_request_idx
  on public.reservation_anomaly_evidence(request_id, observed_at desc);
create index if not exists reservation_anomaly_evidence_parent_idx
  on public.reservation_anomaly_evidence(anomaly_id, observed_at desc);

create table if not exists public.renter_risk_profiles (
  renter_id uuid not null references public.profiles(id) on delete cascade,
  admin_lane text not null check (admin_lane in ('internal', 'external')),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  local_risk_score smallint not null default 0 check (local_risk_score between 0 and 100),
  local_risk_level text not null default 'normal' check (local_risk_level in ('normal', 'low', 'moderate', 'high', 'critical')),
  active_anomaly_count integer not null default 0,
  reservations_30d integer not null default 0,
  successful_occurrences_30d integer not null default 0,
  no_show_occurrences_30d integer not null default 0,
  cancelled_occurrences_30d integer not null default 0,
  late_cancellations_30d integer not null default 0,
  payment_expirations_30d integer not null default 0,
  last_adverse_at timestamptz,
  last_evaluated_at timestamptz not null default now(),
  primary key (renter_id, admin_lane, facility_id)
);

create table if not exists public.reservation_anomaly_evaluation_queue (
  renter_id uuid not null references public.profiles(id) on delete cascade,
  admin_lane text not null check (admin_lane in ('internal', 'external')),
  reason_keys text[] not null default '{}',
  requested_at timestamptz not null default now(),
  next_attempt_at timestamptz not null default now(),
  attempt_count integer not null default 0,
  last_error text,
  primary key (renter_id, admin_lane)
);

alter table public.app_notifications
  add column if not exists anomaly_id uuid references public.reservation_anomalies(id) on delete cascade;

create unique index if not exists app_notifications_anomaly_once_idx
  on public.app_notifications(recipient_id, anomaly_id, kind)
  where anomaly_id is not null;

alter table public.audit_entries
  drop constraint if exists audit_entries_entity_type_check,
  add constraint audit_entries_entity_type_check
    check (entity_type in ('facility', 'reservation', 'account', 'system', 'anomaly'));

insert into public.anomaly_rules(
  rule_key, enabled, mode, applicable_lanes, signal_family, base_weight,
  evaluation_window_hours, configuration, rule_version
) values
  ('consecutive_no_show_cluster', true, 'active', array['internal','external'], 'attendance', 30, 168,
    '{"threshold":3,"close_hours":72,"consecutive_dates":3}'::jsonb, 1),
  ('repeated_no_show', true, 'active', array['internal','external'], 'attendance', 15, 720,
    '{"tiers":[{"count":2,"points":15,"severity":"moderate"},{"count":3,"points":25,"severity":"high"},{"count":4,"points":35,"severity":"critical"}]}'::jsonb, 1),
  ('excessive_reservation_creation', true, 'observe', array['internal','external'], 'creation', 10, 168,
    '{"requests_24h":6,"requests_7d":12}'::jsonb, 1),
  ('facility_slot_hoarding', true, 'observe', array['internal','external'], 'hoarding', 20, 720,
    '{"baseline_min":30,"adverse_prime_occurrences":3,"blocked_hours":6,"adverse_ratio":0.6}'::jsonb, 1),
  ('repeated_late_cancellation', true, 'active', array['internal','external'], 'cancellation', 18, 720,
    '{"threshold":3,"lead_hours":12}'::jsonb, 1),
  ('reserve_cancel_reserve_cycle', true, 'active', array['internal','external'], 'cancellation', 15, 720,
    '{"threshold":3,"new_request_hours":72}'::jsonb, 1),
  ('overlapping_reservations', true, 'active', array['internal','external'], 'overlap', 12, 720,
    '{"minutes":30,"second_pair_points":20}'::jsonb, 1),
  ('abnormal_duration', true, 'observe', array['internal','external'], 'duration', 12, 1440,
    '{"baseline_min":30,"threshold_count":2,"window_days":60,"multiplier":1.5}'::jsonb, 1),
  ('missed_down_payment', true, 'active', array['external'], 'payment', 25, 720,
    '{"threshold":3,"terminal_reason_code":"down_payment_deadline"}'::jsonb, 1),
  ('payment_deadline_expiration', true, 'active', array['external'], 'payment', 18, 1440,
    '{"threshold":3,"terminal_reason_codes":["down_payment_deadline","balance_payment_deadline"]}'::jsonb, 1),
  ('full_payment_deadline_failure', true, 'active', array['external'], 'payment', 20, 1440,
    '{"threshold":2,"terminal_reason_code":"balance_payment_deadline"}'::jsonb, 1),
  ('payment_slot_blocking', true, 'observe', array['external'], 'hoarding', 20, 1440,
    '{"baseline_min":30,"threshold":3,"blocked_hours":6,"terminal_reason_codes":["down_payment_deadline","balance_payment_deadline"]}'::jsonb, 1)
on conflict (rule_key) do update
set enabled = excluded.enabled,
    mode = excluded.mode,
    applicable_lanes = excluded.applicable_lanes,
    signal_family = excluded.signal_family,
    base_weight = excluded.base_weight,
    evaluation_window_hours = excluded.evaluation_window_hours,
    configuration = excluded.configuration,
    rule_version = excluded.rule_version,
    updated_at = now();

alter table public.anomaly_rules enable row level security;
alter table public.facility_anomaly_baselines enable row level security;
alter table public.reservation_anomalies enable row level security;
alter table public.reservation_anomaly_evidence enable row level security;
alter table public.renter_risk_profiles enable row level security;
alter table public.reservation_anomaly_evaluation_queue enable row level security;

revoke all on public.anomaly_rules from public, anon, authenticated;
revoke all on public.facility_anomaly_baselines from public, anon, authenticated;
revoke all on public.reservation_anomalies from public, anon, authenticated;
revoke all on public.reservation_anomaly_evidence from public, anon, authenticated;
revoke all on public.renter_risk_profiles from public, anon, authenticated;
revoke all on public.reservation_anomaly_evaluation_queue from public, anon, authenticated;
grant select on public.reservation_anomalies to authenticated;
grant select on public.reservation_anomaly_evidence to authenticated;
grant select on public.renter_risk_profiles to authenticated;

drop policy if exists reservation_anomalies_admin_select on public.reservation_anomalies;
create policy reservation_anomalies_admin_select
on public.reservation_anomalies for select to authenticated
using (
  public.admin_lane() = admin_lane
  and public.can_manage_facility(facility_id)
);

drop policy if exists reservation_anomaly_evidence_admin_select on public.reservation_anomaly_evidence;
create policy reservation_anomaly_evidence_admin_select
on public.reservation_anomaly_evidence for select to authenticated
using (
  exists (
    select 1
    from public.reservation_anomalies a
    where a.id = anomaly_id
      and public.admin_lane() = a.admin_lane
      and public.can_manage_facility(a.facility_id)
  )
  and public.can_manage_reservation(request_id)
);

drop policy if exists renter_risk_profiles_admin_select on public.renter_risk_profiles;
create policy renter_risk_profiles_admin_select
on public.renter_risk_profiles for select to authenticated
using (
  public.admin_lane() = admin_lane
  and public.can_manage_facility(facility_id)
);

drop policy if exists audit_entries_select_authorized on public.audit_entries;
drop policy if exists audit_entries_select_internal_admin on public.audit_entries;
create policy audit_entries_select_authorized
on public.audit_entries for select to authenticated
using (
  (public.is_internal_admin() and entity_type <> 'anomaly')
  or (entity_type = 'facility' and entity_id is not null and public.can_manage_facility(entity_id))
  or (entity_type = 'reservation' and entity_id is not null and public.can_manage_reservation(entity_id))
  or (
    entity_type = 'anomaly'
    and entity_id is not null
    and exists (
      select 1
      from public.reservation_anomalies a
      where a.id = entity_id
        and public.admin_lane() = a.admin_lane
        and public.can_manage_facility(a.facility_id)
    )
  )
);

create or replace function public.get_audit_entries(
  p_search text default null,
  p_actor text default null,
  p_entity_type text default null,
  p_material_only boolean default false,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  with filtered as (
    select a.*, p.email as actor_email
    from public.audit_entries a
    left join public.profiles p on p.id = a.actor_id
    where a.entity_type <> 'anomaly'
      and (nullif(trim(p_search), '') is null or concat_ws(' ', a.actor_name, a.target_label, a.action, a.reason, a.details::text, a.before_values::text, a.after_values::text) ilike '%' || trim(p_search) || '%')
      and (p_actor is null or a.actor_name = p_actor)
      and (p_entity_type is null or a.entity_type = p_entity_type)
      and (not p_material_only or a.material)
      and (p_from is null or a.created_at >= p_from)
      and (p_to is null or a.created_at < p_to)
  ), page as (
    select * from filtered
    where p_before_created_at is null
      or (created_at, id) < (p_before_created_at, p_before_id)
    order by created_at desc, id desc
    limit p_limit
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(page) || jsonb_build_object(
      'revertable', entity_type = 'facility' and action = 'updated'
    ) order by created_at desc, id desc) from page), '[]'::jsonb),
    'total', (select count(*) from filtered),
    'actors', coalesce((select jsonb_agg(actor_name order by actor_name) from (select distinct actor_name from filtered) actors), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

notify pgrst, 'reload schema';
