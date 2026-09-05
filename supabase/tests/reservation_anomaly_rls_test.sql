begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(20);

-- No authenticated session yet: table-level grants only, independent of RLS.
select is(
  has_table_privilege('authenticated', 'public.anomaly_rules', 'SELECT'),
  false,
  'authenticated role has no SELECT grant on anomaly_rules'
);
select is(
  has_table_privilege('authenticated', 'public.facility_anomaly_baselines', 'SELECT'),
  false,
  'authenticated role has no SELECT grant on facility_anomaly_baselines'
);
select is(
  has_table_privilege('authenticated', 'public.reservation_anomaly_evaluation_queue', 'SELECT'),
  false,
  'authenticated role has no SELECT grant on reservation_anomaly_evaluation_queue'
);
select is(
  has_table_privilege('authenticated', 'public.reservation_anomalies', 'UPDATE'),
  false,
  'authenticated role has no direct UPDATE grant on reservation_anomalies -- state changes only via transition_reservation_anomaly()'
);
select is(
  has_table_privilege('authenticated', 'public.reservation_anomalies', 'INSERT'),
  false,
  'authenticated role has no direct INSERT grant on reservation_anomalies'
);

create temp table anomaly_rls_ids as
select
  '9a000000-0000-0000-0000-000000000001'::uuid as internal_admin_a_id,
  '9a000000-0000-0000-0000-000000000002'::uuid as external_admin_a_id,
  '9a000000-0000-0000-0000-000000000003'::uuid as internal_admin_b_id,
  '9a000000-0000-0000-0000-000000000004'::uuid as renter_x_id,
  '9a000000-0000-0000-0000-000000000005'::uuid as renter_y_id,
  '9a000000-0000-0000-0000-000000000006'::uuid as renter_z_id,
  '9a100000-0000-0000-0000-000000000001'::uuid as facility_1_id,
  '9a100000-0000-0000-0000-000000000002'::uuid as facility_2_id,
  '9a200000-0000-0000-0000-000000000001'::uuid as request_1_id,
  '9a200000-0000-0000-0000-000000000002'::uuid as request_2_id,
  '9a200000-0000-0000-0000-000000000003'::uuid as request_3_id,
  '9a400000-0000-0000-0000-000000000001'::uuid as anomaly_1_id,
  '9a400000-0000-0000-0000-000000000002'::uuid as anomaly_2_id,
  '9a400000-0000-0000-0000-000000000003'::uuid as anomaly_3_id,
  '9a600000-0000-0000-0000-000000000001'::uuid as anomaly_audit_id,
  '9a600000-0000-0000-0000-000000000002'::uuid as system_audit_id;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, email_change, email_change_token_new, recovery_token
)
select
  '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  email, 'test-password', now(),
  jsonb_build_object('provider', 'email', 'providers', array['email']),
  jsonb_build_object('full_name', full_name), now(), now(), '', '', '', ''
from (values
  ('9a000000-0000-0000-0000-000000000001'::uuid, 'anomaly-internal-admin-a@example.test', 'Anomaly Internal Admin A'),
  ('9a000000-0000-0000-0000-000000000002'::uuid, 'anomaly-external-admin-a@example.test', 'Anomaly External Admin A'),
  ('9a000000-0000-0000-0000-000000000003'::uuid, 'anomaly-internal-admin-b@example.test', 'Anomaly Internal Admin B'),
  ('9a000000-0000-0000-0000-000000000004'::uuid, 'anomaly-renter-x@example.test', 'Anomaly Renter X'),
  ('9a000000-0000-0000-0000-000000000005'::uuid, 'anomaly-renter-y@example.test', 'Anomaly Renter Y'),
  ('9a000000-0000-0000-0000-000000000006'::uuid, 'anomaly-renter-z@example.test', 'Anomaly Renter Z')
) as u(id, email, full_name)
on conflict (id) do update
set email = excluded.email,
    raw_user_meta_data = excluded.raw_user_meta_data,
    updated_at = now();

insert into public.profiles (
  id, email, full_name, campus_claim, campus_id, unit, role, account_status,
  verification_status, onboarding_complete, created_at
)
values
  ('9a000000-0000-0000-0000-000000000001', 'anomaly-internal-admin-a@example.test',
   'Anomaly Internal Admin A', 'none', null, null, 'internal_admin', 'active',
   'none', true, '2030-03-01 00:00+00'),
  ('9a000000-0000-0000-0000-000000000002', 'anomaly-external-admin-a@example.test',
   'Anomaly External Admin A', 'none', null, null, 'external_admin', 'active',
   'none', true, '2030-03-01 00:01+00'),
  ('9a000000-0000-0000-0000-000000000003', 'anomaly-internal-admin-b@example.test',
   'Anomaly Internal Admin B', 'none', null, null, 'internal_admin', 'active',
   'none', true, '2030-03-01 00:02+00'),
  ('9a000000-0000-0000-0000-000000000004', 'anomaly-renter-x@example.test',
   'Anomaly Renter X', 'student', 'ANOM-X', 'BS IT', 'user', 'active',
   'verified', true, '2030-03-01 00:03+00'),
  ('9a000000-0000-0000-0000-000000000005', 'anomaly-renter-y@example.test',
   'Anomaly Renter Y', 'none', null, null, 'user', 'active', 'none', true,
   '2030-03-01 00:04+00'),
  ('9a000000-0000-0000-0000-000000000006', 'anomaly-renter-z@example.test',
   'Anomaly Renter Z', 'student', 'ANOM-Z', 'BS IT', 'user', 'active',
   'verified', true, '2030-03-01 00:05+00')
on conflict (id) do update
set email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    account_status = excluded.account_status,
    verification_status = excluded.verification_status,
    updated_at = now();

insert into public.facilities (
  id, name, building, category, capacity, status, open_days, open_time,
  close_time, updated_by_name
)
values
  ('9a100000-0000-0000-0000-000000000001', 'Anomaly RLS Room 1', 'Anomaly Building',
   'Anomaly RLS Test', 40, 'active', array[true,true,true,true,true,true,true],
   '07:00', '19:00', 'Test'),
  ('9a100000-0000-0000-0000-000000000002', 'Anomaly RLS Room 2', 'Anomaly Building',
   'Anomaly RLS Test', 40, 'active', array[true,true,true,true,true,true,true],
   '07:00', '19:00', 'Test')
on conflict (id) do update
set name = excluded.name,
    status = excluded.status,
    updated_at = now();

-- Facility admin assignments no longer exist as an authorization concept
-- (20260830120000_global_admin_authorization.sql): an active internal_admin
-- sees every internal-lane anomaly regardless of which facility it is at,
-- and likewise for external_admin/external-lane. Only the reservation lane
-- (admin_lane) isolates visibility below -- Internal Admin A and Internal
-- Admin B both see every internal-lane anomaly, at both facility 1 and
-- facility 2.

insert into public.reservation_requests (
  id, requester_id, facility_id, requester_name, requester_role, facility_name,
  facility_building, facility_capacity, purpose, headcount, status,
  reservation_status, held_for_verification, payment_amount_centavos,
  payment_status, payment_method_id, created_at, admin_lane
)
values
  ('9a200000-0000-0000-0000-000000000001', '9a000000-0000-0000-0000-000000000004',
   '9a100000-0000-0000-0000-000000000001', 'Anomaly Renter X', 'user',
   'Anomaly RLS Room 1', 'Anomaly Building', 40, 'Internal lane at facility 1',
   10, 'approved', 'completed', false, 0, 'not_required', null,
   '2030-03-02 00:00+00', 'internal'),
  ('9a200000-0000-0000-0000-000000000002', '9a000000-0000-0000-0000-000000000005',
   '9a100000-0000-0000-0000-000000000001', 'Anomaly Renter Y', 'user',
   'Anomaly RLS Room 1', 'Anomaly Building', 40, 'External lane at facility 1',
   10, 'approved', 'completed', false, 50000, 'captured', null,
   '2030-03-02 00:10+00', 'external'),
  ('9a200000-0000-0000-0000-000000000003', '9a000000-0000-0000-0000-000000000006',
   '9a100000-0000-0000-0000-000000000002', 'Anomaly Renter Z', 'user',
   'Anomaly RLS Room 2', 'Anomaly Building', 40, 'Internal lane at facility 2',
   10, 'approved', 'completed', false, 0, 'not_required', null,
   '2030-03-02 00:20+00', 'internal');

insert into public.reservation_anomalies (
  id, renter_id, admin_lane, facility_id, rule_key, correlation_key,
  evidence_fingerprint, detection_mode, severity, title, explanation,
  window_started_at, window_ended_at, last_contributing_at
)
values
  ('9a400000-0000-0000-0000-000000000001', '9a000000-0000-0000-0000-000000000004',
   'internal', '9a100000-0000-0000-0000-000000000001', 'repeated_no_show',
   'corr-1', 'fp-1', 'active', 'high', 'Repeated no-shows',
   'Three no-shows in the last 30 days.', '2030-02-01 00:00+00',
   '2030-03-01 00:00+00', '2030-02-28 00:00+00'),
  ('9a400000-0000-0000-0000-000000000002', '9a000000-0000-0000-0000-000000000005',
   'external', '9a100000-0000-0000-0000-000000000001', 'missed_down_payment',
   'corr-2', 'fp-2', 'active', 'high', 'Missed down payment',
   'Three missed down payments in the last 30 days.', '2030-02-01 00:00+00',
   '2030-03-01 00:00+00', '2030-02-28 00:00+00'),
  ('9a400000-0000-0000-0000-000000000003', '9a000000-0000-0000-0000-000000000006',
   'internal', '9a100000-0000-0000-0000-000000000002', 'repeated_no_show',
   'corr-3', 'fp-3', 'active', 'high', 'Repeated no-shows',
   'Three no-shows in the last 30 days.', '2030-02-01 00:00+00',
   '2030-03-01 00:00+00', '2030-02-28 00:00+00');

insert into public.reservation_anomaly_evidence (
  anomaly_id, request_id, facility_id, evidence_role, observed_at
)
values
  ('9a400000-0000-0000-0000-000000000001', '9a200000-0000-0000-0000-000000000001',
   '9a100000-0000-0000-0000-000000000001', 'no_show', '2030-02-20 00:00+00'),
  ('9a400000-0000-0000-0000-000000000002', '9a200000-0000-0000-0000-000000000002',
   '9a100000-0000-0000-0000-000000000001', 'payment_expiry', '2030-02-20 00:00+00'),
  ('9a400000-0000-0000-0000-000000000003', '9a200000-0000-0000-0000-000000000003',
   '9a100000-0000-0000-0000-000000000002', 'no_show', '2030-02-20 00:00+00');

insert into public.renter_risk_profiles (
  renter_id, admin_lane, facility_id, local_risk_score, local_risk_level
)
values
  ('9a000000-0000-0000-0000-000000000004', 'internal', '9a100000-0000-0000-0000-000000000001', 35, 'moderate'),
  ('9a000000-0000-0000-0000-000000000005', 'external', '9a100000-0000-0000-0000-000000000001', 40, 'moderate'),
  ('9a000000-0000-0000-0000-000000000006', 'internal', '9a100000-0000-0000-0000-000000000002', 30, 'moderate');

insert into public.audit_entries (
  id, entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
  action, details, source_type, source_id, created_at
)
values
  ('9a600000-0000-0000-0000-000000000001', 'anomaly', '9a400000-0000-0000-0000-000000000001',
   'Repeated no-shows', '9a000000-0000-0000-0000-000000000001', 'system', 'system',
   'anomaly detected', jsonb_build_object('event_key', 'ANOMALY_DETECTED'),
   'reservation_anomaly:test', '9a600000-0000-0000-0000-000000000001', '2030-02-28 00:00+00'),
  ('9a600000-0000-0000-0000-000000000002', 'system', null,
   'System maintenance', null, 'system', 'system',
   'ran nightly job', '{}'::jsonb,
   'system:test', '9a600000-0000-0000-0000-000000000002', '2030-02-28 00:01+00');

-- Renter: no SELECT path into any anomaly-related table, including own rows.
select set_config('request.jwt.claim.sub', (select renter_x_id::text from anomaly_rls_ids), false);
set local role authenticated;

select is(
  (select count(*) from public.reservation_anomalies),
  0::bigint,
  'a renter sees zero reservation_anomalies rows, including their own'
);
select is(
  (select count(*) from public.reservation_anomaly_evidence),
  0::bigint,
  'a renter sees zero reservation_anomaly_evidence rows'
);
select is(
  (select count(*) from public.renter_risk_profiles),
  0::bigint,
  'a renter sees zero renter_risk_profiles rows'
);

-- Internal Admin A: no facility assignment, internal lane.
select set_config('request.jwt.claim.sub', (select internal_admin_a_id::text from anomaly_rls_ids), false);
set local role authenticated;

select is(
  (select array_agg(id order by id) from public.reservation_anomalies),
  array[
    (select anomaly_1_id from anomaly_rls_ids),
    (select anomaly_3_id from anomaly_rls_ids)
  ],
  'internal admin A sees every internal-lane anomaly, at both facility 1 and facility 2'
);
select is(
  (select array_agg(anomaly_id order by anomaly_id) from public.reservation_anomaly_evidence),
  array[
    (select anomaly_1_id from anomaly_rls_ids),
    (select anomaly_3_id from anomaly_rls_ids)
  ],
  'internal admin A sees evidence for every visible internal-lane anomaly'
);
select is(
  (select array_agg(renter_id order by renter_id) from public.renter_risk_profiles),
  array[
    (select renter_x_id from anomaly_rls_ids),
    (select renter_z_id from anomaly_rls_ids)
  ],
  'internal admin A sees every internal-lane risk profile, not just facility 1''s'
);
select is(
  (select count(*) from public.audit_entries where entity_type = 'anomaly'),
  1::bigint,
  'internal admin A sees the internal-lane anomaly audit entry'
);
select is(
  (select count(*) from public.audit_entries where entity_type = 'system'),
  1::bigint,
  'internal admin A keeps broad read access to non-anomaly audit entries'
);
select ok(
  not exists (
    select 1 from jsonb_array_elements(public.get_audit_entries() -> 'rows') entry
    where entry ->> 'entity_type' = 'anomaly'
  ),
  'get_audit_entries() never returns anomaly-entity rows, even to an internal admin who could see one directly'
);

-- External Admin A: no facility assignment, external lane.
select set_config('request.jwt.claim.sub', (select external_admin_a_id::text from anomaly_rls_ids), false);
set local role authenticated;

select is(
  (select array_agg(id order by id) from public.reservation_anomalies),
  array[(select anomaly_2_id from anomaly_rls_ids)],
  'external admin A sees only the external-lane anomaly'
);
select is(
  (select array_agg(anomaly_id order by anomaly_id) from public.reservation_anomaly_evidence),
  array[(select anomaly_2_id from anomaly_rls_ids)],
  'external admin A sees only evidence for their visible anomaly'
);
select is(
  (select array_agg(renter_id order by renter_id) from public.renter_risk_profiles),
  array[(select renter_y_id from anomaly_rls_ids)],
  'external admin A sees only the external-lane risk profile'
);
select is(
  (select count(*) from public.audit_entries where entity_type = 'system'),
  0::bigint,
  'external admin A does not get the internal admin''s broad non-anomaly audit access'
);

-- Internal Admin B: no facility assignment, same lane as Internal Admin A.
select set_config('request.jwt.claim.sub', (select internal_admin_b_id::text from anomaly_rls_ids), false);
set local role authenticated;

select is(
  (select array_agg(id order by id) from public.reservation_anomalies),
  array[
    (select anomaly_1_id from anomaly_rls_ids),
    (select anomaly_3_id from anomaly_rls_ids)
  ],
  'internal admin B sees the same internal-lane anomalies as internal admin A, at both facilities'
);
select is(
  (select array_agg(anomaly_id order by anomaly_id) from public.reservation_anomaly_evidence),
  array[
    (select anomaly_1_id from anomaly_rls_ids),
    (select anomaly_3_id from anomaly_rls_ids)
  ],
  'internal admin B sees evidence for every visible internal-lane anomaly'
);

select * from finish();
rollback;
