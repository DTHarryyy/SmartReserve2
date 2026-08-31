# Explainable Reservation Anomaly Detection and Risk Monitoring

## Summary

Implement a deterministic, PostgreSQL-backed anomaly engine in the SmartReserve Flutter/Supabase repository at `D:\Projects\smartreserve`. Preserve the existing immutable `admin_lane` classification and additionally enforce facility assignments.

All 12 requested rules will be implemented. Objective outcome rules will score immediately; volume-, demand-, and facility-baseline-dependent rules will initially run in observe-only mode because the linked production database currently has only 5 reservations, 5 occurrences, no no-shows, no cancellations, and no payment expirations.

Risk remains advisory. It never automatically rejects, cancels, suspends, or bans a renter. Renters cannot query anomaly or risk records in V1.

## A. Current System Analysis

### Application architecture

- Flutter application entry: `lib/main.dart`.
- Central client state and navigation: `lib/app/app_state.dart`, `lib/app/app_view.dart`, `lib/app/app_shell.dart`.
- Supabase repository and RPC adapter: `lib/backend/supabase_service.dart`.
- Reservation models: `lib/model/reservation.dart`, `lib/model/payment.dart`.
- Reservation queue/review: `lib/features/reservations/reservations_screen.dart`, `decision_panel.dart`, `reservation_checks.dart`, and `conflict_engine.dart`.
- Responsive breakpoints already exist in `lib/theme/sr_tokens.dart`: compact `<600`, medium `600–899`, expanded `900–1179`, desktop `≥1180`.
- Dark and light themes already exist and must be reused.
- There is no general admin dashboard. Operational metrics belong at the top of the new Anomaly Center, with a navigation badge in `side_nav.dart`.
- `D:\Projects\smartreserve-api` is an unused Laravel skeleton with no API routes or references from Flutter. It must remain unchanged.

### Live Supabase state

All 42 checked-in migrations through `20260829100000_feedback_sentiment_analysis.sql` are deployed to project `tyniwgrvfxkfzhbiufib`.

Relevant objects:

- `profiles`
  - Roles are exactly `user`, `internal_admin`, and `external_admin`.
  - Campus classifications are `campus_claim = student|faculty|staff|none`.
  - Verification uses `verification_status = none|pending|verified|rejected`.
- `requester_admin_lane(user_id)` returns:
  - `internal` only for verified `student`, `faculty`, or `staff`;
  - `external` otherwise.
- `reservation_requests.admin_lane` snapshots that classification at submission and is immutable.
- `admin_lane(admin_id)` maps:
  - `internal_admin → internal`;
  - `external_admin → external`.
- `facility_admin_assignments` and `can_manage_reservation()` additionally restrict administrators to assigned facilities.
- RLS already protects reservation requests, occurrences, events, payments, files, and permits through requester ownership or `can_manage_reservation()`.

### Payment workflow

- `reservation_requests.payment_exemption` snapshots `verified_student`, `verified_faculty`, or `none`.
- Verified students and faculty receive zero-priced quotes.
- Verified staff remain in the internal lane but are not currently payment-exempt.
- External paid requests enter `awaiting_payment`, hold slots, and use:
  - `payment_due_at` for down payment;
  - `balance_due_at` for remaining payment.
- `expire_due_reservations()` distinguishes missed down payment from missed balance only through human-readable event/reason text.
- Payment anomaly eligibility must require all of:
  - `admin_lane = 'external'`;
  - `payment_exemption = 'none'`;
  - `total_amount_centavos > 0`;
  - `legacy_financial_state = false`.
- Payment anomalies therefore remain unavailable to Internal Admin even for a paid verified staff reservation.

### Attendance and cancellation

- Attendance is already separate from reservation approval:
  - `reservation_occurrences.lifecycle_stage = booked|checked_in|completed|no_show`.
- `reservation_action()` supports `check_in`, `complete`, and `no_show`.
- No-show marking currently opens 15 minutes after the occurrence starts.
- Attendance lacks canonical marked-at, marked-by, reason, and correction metadata.
- Cancellation changes `booking_state` and writes a `reservation_event`, but occurrences lack `cancelled_at` and `cancelled_by`.
- Flutter currently hardcodes `noShows: 0` in `AppState._toReservationRequest()`, so the existing “prior no-shows” queue flag is not production-backed.

### Audit and notification infrastructure

- `reservation_events` is the append-only operational activity stream.
- `capture_reservation_audit()` mirrors reservation events into `audit_entries`.
- `audit_entries` uses `(source_type, source_id)` for idempotency.
- `app_notifications` already supports RLS, realtime delivery, read state, and navigation.
- These systems will be extended rather than duplicated.
- There is no system-owner or super-admin role. A facility `owner` is only an assignment role and must not widen lane access.

## B. Current Gaps

- No persisted anomaly cases, evidence links, rules, baselines, evaluation queue, or risk profiles.
- No authoritative aggregate no-show history is exposed to Flutter.
- Attendance corrections cannot be recorded cleanly after a mistaken no-show/completion.
- Cancellation timing is not stored at occurrence level, making late-cancellation calculations brittle.
- Payment expiration reasons are strings rather than stable codes.
- Same-facility held/booked overlap is prevented by an exclusion constraint, but same-renter overlap across facilities is not evaluated.
- No definition or baseline exists for facility-specific prime slots or abnormal duration.
- Existing production volume is insufficient for statistical threshold calibration.
- Page-level queries currently load full nested reservations; an anomaly center needs paginated, purpose-built RPCs.
- Existing `audit_entries` policy lets Internal Admin read broad audit data. Anomaly audit rows must explicitly exclude external-lane anomaly information from that broad access.
- There is no anomaly review UI, risk summary in reservation review, notification routing, false-positive workflow, or risk decay.

## C. Proposed Architecture

```text
Reservation / occurrence / payment state change
        ↓
Lightweight evaluation-queue trigger
        ↓
Near-real-time PostgreSQL worker (≤1 minute)
        ↓
Lane eligibility + facility scope
        ↓
Rule configuration and facility baseline checks
        ↓
Deterministic rule evaluators
        ↓
Per-facility anomaly projection + canonical evidence links
        ↓
Decay and family-capped risk recalculation
        ↓
Risk-profile cache update
        ↓
Scoped high/critical notification and audit event
        ↓
Internal or External Anomaly Center
        ↓
Acknowledge / Resolve / False Positive
```

Key decisions:

- PostgreSQL functions and `pg_cron` are authoritative; no ML and no client-authored scores.
- Lifecycle writes only enqueue evaluation. Detection runs asynchronously within one minute, preventing heavy rule queries from delaying reservation actions.
- A nightly job refreshes facility baselines, expires cleared anomalies, applies decay, and reevaluates recently active renters.
- A lane-wide pattern is projected once per contributing facility. Projections share a `correlation_key`; risk queries count that correlation only once.
- Each projection contains evidence only for its facility. An admin assigned to several contributing facilities sees their combined evidence; other facility records remain hidden.
- Flutter reads cached anomalies/risk summaries. Opening a page never scans lifetime reservation history.
- The UI labels the result “Risk in your assigned portfolio” when facility assignments prevent a genuinely system-wide view.

## D. Database Changes

### Migration order

1. `20260829110000_attendance_and_terminal_outcomes.sql`
2. `20260829120000_reservation_anomaly_foundation.sql`
3. `20260829130000_reservation_anomaly_engine.sql`
4. `20260829140000_reservation_anomaly_integration.sql`
5. `20260829150000_reservation_anomaly_backfill.sql`

### Required for V1

#### Attendance and terminal outcomes

Extend `reservation_occurrences` with:

- `attendance_marked_at timestamptz`;
- `attendance_marked_by uuid references profiles(id) on delete set null`;
- `attendance_reason text`;
- `cancelled_at timestamptz`;
- `cancelled_by uuid references profiles(id) on delete set null`;
- `cancellation_reason text`.

Extend `reservation_requests` with:

- `terminal_at timestamptz`;
- `terminal_reason_code text` constrained to:
  - `stale_pending`;
  - `manual_expiration`;
  - `down_payment_deadline`;
  - `balance_payment_deadline`.

Keep `lifecycle_stage`; do not add `no_show` to `reservation_status`.

Add:

- `record_occurrence_attendance(...)` for normal check-in/completion/no-show transitions;
- `correct_occurrence_attendance(...)` for `no_show ↔ completed` correction with a mandatory reason;
- a replacement `reservation_action(...)` wrapper that delegates attendance actions to the new function while retaining its public signature;
- a replacement `cancel_reservation_action(...)` that populates cancellation metadata;
- a replacement `expire_due_reservations(...)` that populates canonical terminal codes.

Attendance transitions:

- `booked → checked_in` from 30 minutes before start;
- `booked → no_show` after the existing 15-minute grace period;
- `checked_in → completed`;
- terminal corrections require an assigned matching-lane administrator, a reason of at least three characters, and a new audit event.
- Do not auto-mark an ended booking as no-show; it remains “attendance requires review” until an administrator records an outcome.

#### `anomaly_rules`

Fields:

- `rule_key text primary key`;
- `enabled boolean not null`;
- `mode text check (mode in ('active','observe'))`;
- `applicable_lanes text[]`;
- `signal_family text`;
- `base_weight smallint check (base_weight between 0 and 100)`;
- `evaluation_window_hours integer`;
- `configuration jsonb`;
- `rule_version integer`;
- `updated_at timestamptz`;
- `updated_by uuid nullable`.

Use `anomaly_rule_config_is_valid(rule_key, configuration)` as a CHECK helper. Revoke direct authenticated writes. V1 rule changes are migration/service-role operations only; neither administrator role receives rule-configuration permission.

#### `facility_anomaly_baselines`

Fields:

- `facility_id uuid primary key`;
- `window_started_at`, `window_ended_at`;
- `sample_count integer`;
- `duration_p50_minutes`, `duration_p90_minutes`;
- `prime_slots jsonb`;
- `calculated_at timestamptz`.

`prime_slots` stores only weekday/hour buckets and counts—no renter information. A facility needs at least 30 eligible historical occurrences before duration/prime-slot rules can score.

#### `reservation_anomalies`

Fields:

- `id uuid primary key`;
- `renter_id uuid references profiles(id)`;
- `admin_lane text check (admin_lane in ('internal','external'))`;
- `facility_id uuid references facilities(id)`;
- `rule_key text references anomaly_rules(rule_key)`;
- `correlation_key text not null`;
- `evidence_fingerprint text not null`;
- `detection_mode text check (detection_mode in ('active','observe'))`;
- `severity text check (severity in ('info','low','moderate','high','critical'))`;
- `base_risk_points smallint`;
- `effective_risk_points smallint`;
- `title text`;
- `explanation text`;
- `evidence_summary jsonb`;
- `window_started_at`, `window_ended_at`, `last_contributing_at`;
- `status text check (status in ('open','acknowledged','resolved','false_positive'))`;
- `acknowledged_at`, `acknowledged_by`;
- `resolved_at`, `resolved_by`;
- `resolution_code`, `resolution_note`;
- `rule_version`;
- `first_detected_at`, `last_detected_at`, `last_evaluated_at`;
- `created_at`, `updated_at`.

Constraints/indexes:

- Partial unique index on `(renter_id, admin_lane, rule_key, facility_id)` where status is `open` or `acknowledged`.
- Indexes on:
  - `(admin_lane, facility_id, status, severity, last_detected_at desc)`;
  - `(renter_id, admin_lane, status)`;
  - `(correlation_key)`;
  - `(rule_key, status, last_evaluated_at)`.
- `evidence_summary` contains counts, thresholds, ratios, windows, and restricted-record counts, but no names, emails, payment references, or reservation IDs.

#### `reservation_anomaly_evidence`

Fields:

- `id uuid primary key`;
- `anomaly_id uuid references reservation_anomalies(id) on delete cascade`;
- `request_id uuid references reservation_requests(id)`;
- `occurrence_id uuid nullable references reservation_occurrences(id)`;
- `facility_id uuid references facilities(id)`;
- `evidence_role text`;
- `observed_at timestamptz`;
- `measured_value numeric nullable`;
- `created_at timestamptz`.

Use a unique expression index over anomaly/request/occurrence/evidence role. This table holds canonical record references and permits row-level filtering without copying personal data into JSON.

#### `renter_risk_profiles`

Cache at facility grain:

- `renter_id`;
- `admin_lane`;
- `facility_id`;
- `local_risk_score`;
- `local_risk_level`;
- `active_anomaly_count`;
- `reservations_30d`;
- `successful_occurrences_30d`;
- `no_show_occurrences_30d`;
- `cancelled_occurrences_30d`;
- `late_cancellations_30d`;
- `payment_expirations_30d`;
- `last_adverse_at`;
- `last_evaluated_at`;
- primary key `(renter_id, admin_lane, facility_id)`.

Admin-facing RPCs aggregate assigned profile rows and visible anomalies, deduplicate `correlation_key`, then apply the exact risk formula. A single global cached score is deliberately avoided because administrators have different facility assignments.

#### `reservation_anomaly_evaluation_queue`

Fields:

- `renter_id`;
- `admin_lane`;
- `reason_keys text[]`;
- `requested_at`;
- `next_attempt_at`;
- `attempt_count`;
- `last_error`;
- primary key `(renter_id, admin_lane)`.

Repeated lifecycle writes upsert one queue row instead of creating duplicate work.

#### Notification and audit extensions

- Add nullable `anomaly_id` to `app_notifications`.
- Add unique index `(recipient_id, anomaly_id, kind)` where `anomaly_id is not null`.
- Extend the `audit_entries.entity_type` constraint with `anomaly`.
- Recreate `audit_entries_select_authorized` so Internal Admin’s broad audit access excludes `entity_type='anomaly'`; anomaly audit visibility then requires matching lane and facility assignment.
- Update `get_audit_entries()` with the same exclusion.
- No new audit table or notification table.

### RPC/functions

Public authenticated RPCs:

- `get_anomaly_center(filters, cursor, limit)`;
- `get_anomaly_detail(anomaly_id)`;
- `get_reservation_risk_summary(request_id)`;
- `transition_reservation_anomaly(anomaly_id, action, reason_code, note, idempotency_key)`;
- `check_my_reservation_overlaps(starts_at[], ends_at[], exclude_request_id)`.

Service/private functions:

- `enqueue_reservation_anomaly_evaluation(...)`;
- `process_reservation_anomaly_queue(limit)`;
- `evaluate_renter_anomalies(renter_id, lane, as_of, source, notify)`;
- one private evaluator per rule;
- `upsert_reservation_anomaly(...)`;
- `recalculate_renter_risk_profiles(...)`;
- `refresh_facility_anomaly_baselines(...)`;
- `reevaluate_recent_renters(...)`;
- `backfill_reservation_anomalies(dry_run, notify, batch_size, cursor)`.

### Triggers and schedules

Use triggers only as lightweight queue producers:

- Request insert/status/terminal change;
- occurrence lifecycle/cancellation change;
- payment transaction status change.

Schedules:

- Queue processor every minute, maximum 50 renters per run.
- Payment expiration remains every five minutes and enqueues affected renters.
- Baseline refresh nightly.
- Decay/condition-clearing reevaluation nightly for renters active in the previous 180 days or having active anomalies.

### RLS

- `anomaly_rules`, baselines, and queue: no authenticated access.
- `reservation_anomalies`: matching `admin_lane()` and `can_manage_facility(facility_id)`.
- Evidence: parent anomaly visible and `can_manage_reservation(request_id)`.
- Risk profiles: matching lane and `can_manage_facility(facility_id)`.
- No authenticated INSERT/UPDATE/DELETE grants on anomaly objects.
- State changes only through `transition_reservation_anomaly()`.
- Normal renters receive no SELECT path, including for their own rows.
- Security-definer RPCs set `search_path`, validate active role, lane, assignment, page-size bounds, filter values, and requested IDs before returning data.

### Optional future improvements

- Admin rule-configuration UI after governance ownership is established.
- Institution-approved recurring-series exemptions with explicit expiry.
- Statistical/ML models only after sufficient labeled outcomes and false-positive data exist.
- A global risk profile only if SmartReserve later adds an explicit system-owner role.

## E. Backend Changes

No Edge Function or Laravel service is needed.

- `20260829110000_attendance_and_terminal_outcomes.sql`
  - Adds canonical attendance/cancellation/payment-expiration data and correction RPCs.
- `20260829120000_reservation_anomaly_foundation.sql`
  - Creates tables, constraints, indexes, RLS, rule seeds, notification FK, and audit constraint changes.
- `20260829130000_reservation_anomaly_engine.sql`
  - Implements baselines, all rule evaluators, deduplication, decay, risk aggregation, queue processing, and schedules.
- `20260829140000_reservation_anomaly_integration.sql`
  - Adds queue triggers, scoped read/action RPCs, notifications, audit integration, and overlap advisory RPC.
- `20260829150000_reservation_anomaly_backfill.sql`
  - Adds bounded dry-run/backfill APIs without immediately processing history.

Modify `lib/backend/supabase_service.dart` to:

- Add typed anomaly-center, detail, risk-summary, transition, attendance-correction, and overlap-check methods to `SmartReserveBackend`.
- Parse cursor-paginated RPC responses.
- Extend `BackendNotification` with `anomalyId`.
- Extend occurrence parsing with attendance/cancellation metadata.
- Keep `_reservationSelect` for reservation details but do not load anomaly collections through it.

## F. Flutter Changes

### Shared

- Add `lib/model/anomaly.dart`:
  - `AnomalyType`, `AnomalySeverity`, `AnomalyStatus`, `RiskLevel`;
  - `ReservationAnomaly`, `AnomalyEvidence`, `RenterRiskSummary`;
  - `AnomalyFilters`, `AnomalyPage`, `AnomalyMetrics`.
- Modify `lib/model/reservation.dart` for attendance/cancellation metadata.
- Modify `lib/app/app_state.dart`:
  - paginated anomaly state, filters, selected anomaly, detail, metrics;
  - scoped risk-summary cache by reservation;
  - load/retry/paginate/transition/open-reservation methods;
  - clear all anomaly state on sign-out or role change.
- Add `AppView.anomalies` in `lib/app/app_view.dart`.
- Route it in `lib/app/app_shell.dart`.
- Add Anomalies to both admin navigation groups in `lib/widgets/side_nav.dart`, with a high/critical active count badge.

### Internal Admin

- Same shared Anomaly Center component, driven by backend scope.
- Header copy: “Verified-user reservation risk”.
- Metrics exclude all payment categories.
- Available rule filters exclude external-payment-only rules.

### External Admin

- Header copy: “External renter reservation risk”.
- Include payment deadline, missed down payment, balance failure, and payment slot-blocking metrics/filters.
- Do not expose verified-user anomaly counts or records.

### Reservation Details

- Add `lib/features/reservations/risk_summary_card.dart`.
- Insert it in `decision_panel.dart` after the renter/reservation overview and before decision checks.
- Show score, level, last evaluation time, three strongest explanations, and “View risk details”.
- Show “Updating risk…” if an evaluation queue row is pending.
- Add an attendance correction action for terminal occurrence outcomes, requiring a reason.
- Replace the hardcoded `noShows: 0` mapping with the risk summary’s authoritative count.

### Dashboard

There is no existing dashboard. Do not create a new landing page. Put domain-specific metric cards at the top of the Anomaly Center and expose only a navigation badge elsewhere.

### Anomaly Center

Add `lib/features/anomalies/anomalies_screen.dart`:

- Metrics, filters, pagination, refresh, and responsive master/detail behavior.
- Desktop table columns: renter, overall scoped risk, anomaly, facility, evidence summary, detected date, status, actions.
- Compact/tablet cards instead of a squeezed table.
- Default filter: active-mode, open/acknowledged anomalies.
- Optional “Calibration signals” filter reveals observe-mode rows with `0 points` and an explicit “Not affecting risk” label.

### Anomaly Detail

Add `lib/features/anomalies/anomaly_detail.dart`:

- Overview, severity, effective/base points, time window, detection mode, and status.
- “Why was this detected?” explanation generated by the server.
- Evidence timeline with accessible reservation links.
- Restricted evidence is shown only as a count, never an ID/name/facility.
- Renter history for the administrator’s assigned portfolio.
- Acknowledge, resolve, and false-positive actions.
- False-positive reasons:
  - legitimate recurring event;
  - officially approved repeated booking;
  - emergency cancellation;
  - incorrect attendance record;
  - duplicate detection;
  - system error;
  - other.
- `other` requires a note.

### User booking warning

Modify `lib/features/student/booking_sheet.dart`:

- Run the overlap-check RPC before submission.
- Display a nonblocking warning for overlap with the renter’s own active reservations.
- Never show a risk score or anomaly record to the renter.

## G. Rule Definitions

### Applicability matrix

| Rule | Verified student/faculty/staff internal lane | External renter |
|---|---:|---:|
| Repeated no-show | Yes | Yes |
| Consecutive/close no-show cluster | Yes | Yes |
| Excessive reservation creation | Yes, observe | Yes, observe |
| Facility slot hoarding | Yes, observe | Yes, observe |
| Repeated late cancellation | Yes | Yes |
| Reserve/cancel/reserve cycle | Yes | Yes |
| Overlapping reservations | Yes | Yes |
| Abnormal duration | Yes, observe | Yes, observe |
| Missed down payment | No | Yes |
| Payment deadline expiration | No | Yes |
| Full-payment deadline failure | No | Yes |
| Payment-based slot blocking | No | Yes, observe |

Payment rules also require the paid external eligibility predicate, regardless of current profile state.

### Rule specifications

| Rule key | Window and threshold | Points/severity | Evidence and trigger | False-positive controls |
|---|---|---|---|---|
| `consecutive_no_show_cluster` | 3 no-shows within 7 days, either on 3 consecutive Asia/Manila dates or all starting within 72 hours | 30, high | No-show occurrences, dates, gaps, count; trigger on no-show and nightly | Attendance corrections immediately remove corrected evidence |
| `repeated_no_show` | 2/30d = 15 moderate; 3/30d = 25 high; 4+ = 35 critical | Tiered | No-show count/rate and occurrence links; trigger on no-show | Require confirmed/booked occurrence and canonical no-show outcome |
| `excessive_reservation_creation` | 6 distinct requests/24h or 12/7d | Configured 10 moderate, but 0 while observe | Request IDs, intervals, facility count; submission trigger | Count requests, not recurring occurrences; official recurring series alone does not qualify |
| `facility_slot_hoarding` | Baseline ≥30; 3 adverse prime-slot occurrences, ≥6 blocked hours, and ≥60% adverse outcomes in 30d | 20 high, but 0 while observe | Prime buckets, blocked minutes, cancellation/no-show/payment-expiry outcomes | Requires adverse evidence; volume alone is insufficient |
| `repeated_late_cancellation` | 3 cancellations less than 12h before start in 30d | 18 high | `cancelled_at`, scheduled start, lead hours | Emergency/incorrect cancellation can be false-positive |
| `reserve_cancel_reserve_cycle` | 3 cancellation→new-request cycles where the new request is created within 72h, in 30d | 15 moderate | Ordered request/cancellation timeline | Ignore resubmission of the same request and approved recurring occurrences |
| `overlapping_reservations` | One pair overlapping ≥30m = 12 moderate; two pairs/30d = 20 high | Tiered | Range intersection and involved requests; submission/approval trigger | Pending overlap warns only; points begin when both requests are approved, held, or confirmed |
| `abnormal_duration` | Baseline ≥30; 2 occurrences/60d each ≥ `max(p90, 1.5×p50)` for that facility | 12 moderate, but 0 while observe | Facility baseline and duration values | Never compare facilities globally; skip scoring without baseline |
| `missed_down_payment` | 3 `down_payment_deadline` expirations/30d | 25 high | Terminal codes and payment deadline timestamps | External paid eligibility only; submitted proofs awaiting review prevent expiration |
| `payment_deadline_expiration` | 3 deposit-or-balance deadline expirations/60d | 18 high | Canonical expiration codes and request links | Family cap prevents duplicate scoring with specific payment rules |
| `full_payment_deadline_failure` | 2 `balance_payment_deadline` expirations/60d | 20 high | Verified amount, total due, balance deadline, request links | External paid eligibility only |
| `payment_slot_blocking` | Baseline ≥30; 3 prime-slot payment expirations totaling ≥6 hours/60d | 20 high, but 0 while observe | Prime buckets, held duration, terminal codes | Requires repeated payment expiry and prime-slot evidence |

Observe-mode rows are auditable calibration signals but have `effective_risk_points = 0`, create no notifications, and are hidden by default.

## H. Risk Algorithm

For each active/open or active/acknowledged anomaly case:

```text
age_days = as_of - last_contributing_at
decay_factor = 2 ^ (-max(0, age_days - 14) / 45)
decayed_points = round(base_risk_points × decay_factor)
```

- Full points apply for the first 14 days.
- Afterward, points have a 45-day half-life.
- When a rule no longer meets its rolling-window threshold, the anomaly is system-resolved and contributes zero.
- Observe-mode, resolved, and false-positive anomalies contribute zero.

Deduplicate projections by `correlation_key`, taking the maximum contribution among visible facility projections.

Apply signal-family caps:

| Family | Included rules | Cap |
|---|---|---:|
| Attendance | No-show rules | 40 |
| Creation activity | Excessive creation | 15 |
| Cancellation | Late cancellation, reserve/cancel cycle | 30 |
| Overlap | Overlapping reservations | 20 |
| Duration | Abnormal duration | 15 |
| Hoarding | General/payment slot blocking | 25 |
| Payment | Missed deposit, general deadline, balance failure | 35 |

```text
raw_score = sum(min(family_cap, sum(distinct decayed case points)))
success_credit = min(15, 3 × successful completions after latest adverse event in last 90d)
risk_score = clamp(round(raw_score - success_credit), 0, 100)
```

A successful completion requires a canonical `completed` attendance outcome and must not later be corrected to no-show.

Risk levels:

- `0–14`: Normal
- `15–29`: Low
- `30–49`: Moderate
- `50–69`: High
- `70–100`: Critical

Individual anomaly severity remains rule-specific and independent from overall risk. Several moderate anomalies can therefore create a high overall score.

Recalculate after each queued evaluation, attendance correction, anomaly state transition, rule change, and nightly decay run. Audit risk recalculation only when the level changes or the score moves by at least 10 points.

## I. Permission Matrix

| Capability | Internal Admin | External Admin | Renter |
|---|---:|---:|---:|
| View internal anomalies at assigned facilities | Yes | No | No |
| View external anomalies at assigned facilities | No | Yes | No |
| View scoped internal risk | Yes | No | No |
| View scoped external risk | No | Yes | No |
| View external payment anomalies | No | Yes | No |
| Acknowledge/resolve scoped anomaly | Yes | Yes | No |
| Mark scoped anomaly false positive | Yes | Yes | No |
| Correct attendance in matching lane/assignment | Yes | Yes | No |
| View evidence from an unassigned facility | No | No | No |
| Configure rules | No; service/operator only | No; service/operator only | No |
| Receive high/critical notifications | Matching assigned internal cases | Matching assigned external cases | No |
| Automatically reject/cancel based on risk | No | No | No |

Facility `owner` status does not bypass lane checks.

## J. UI/UX Plan

- Desktop (`≥1180`): metric row, filter bar, paginated table, and side detail panel using existing `QueueShell`/table conventions.
- Tablet (`600–1179`): compact rows/cards; selected detail replaces the list with a back action.
- Mobile (`<600`): stacked metric carousel, filter sheet, anomaly cards, full-width detail.
- Loading: skeleton metrics and rows/cards; retain stale results during background refresh.
- Empty:
  - “No active internal anomalies” for Internal Admin;
  - “No active external renter anomalies” for External Admin;
  - separate calibration-empty message.
- Error: retry panel retaining selected filters; safe permission errors display no cached records.
- Permission denied: dedicated empty-state copy and immediate clearing of anomaly state.
- Dark mode: use `context.srColors`, `SrStatusChip`, `PanelCard`, and existing theme tokens; no hardcoded light colors.
- Accessibility: semantic risk labels include score and level; evidence timelines are ordered lists; status never relies on color alone.
- Risk summaries always include explanation, window, points, and last evaluated time.
- No “Suspicious user” label and no unexplained score.

## K. Notification Plan

- Low/moderate and observe-mode anomalies remain in the Anomaly Center only.
- High anomaly: one `anomaly_high` notification per recipient/anomaly.
- Critical anomaly or risk crossing Critical: one `anomaly_critical` notification.
- Recipients must be active admins assigned to the anomaly facility whose role matches `admin_lane`.
- Notification uniqueness is enforced by `(recipient_id, anomaly_id, kind)`.
- A high case escalating to critical may send one additional critical notification.
- Resolution/reopening of the same anomaly does not resend the same tier.
- New evidence after a closed episode creates a new anomaly ID and may notify again.
- Notification navigation opens `AppView.anomalies` and selects the scoped anomaly.
- Notification bodies contain a short explanation and facility name but no payment reference or private evidence.

## L. Audit Plan

Reuse `audit_entries` with `entity_type='anomaly'` and stable `details.event_key`.

Events:

- `ANOMALY_DETECTED`
- `ANOMALY_UPDATED`
- `ANOMALY_ACKNOWLEDGED`
- `ANOMALY_RESOLVED`
- `ANOMALY_FALSE_POSITIVE`
- `RISK_SCORE_RECALCULATED`
- `ANOMALY_RULE_UPDATED`
- `ATTENDANCE_CORRECTED`
- `ANOMALY_BACKFILLED`

Required payload:

- anomaly/renter/lane/facility/rule identifiers;
- rule version;
- before/after status, severity, or score;
- evidence count, not evidence content;
- resolution/false-positive code;
- idempotency/source key;
- backfill or realtime source.

Do not place names, emails, payment references, proof paths, or copied reservation content in audit details. Existing actor fields record the administrator; system evaluations use actor role/name `system`.

An exact false-positive evidence fingerprint remains suppressed. New contributing evidence creates a new fingerprint and may alert; V1 does not automatically alter rule thresholds from false-positive decisions.

## M. Performance Plan

- Evaluate at most 180 days of history and normally only the configured 24-hour/7/30/60/90-day window.
- Add:
  - `(requester_id, admin_lane, created_at desc)` on requests;
  - partial terminal-reason index on `(requester_id, terminal_reason_code, terminal_at desc)`;
  - partial attendance index on `(lifecycle_stage, starts_at desc, request_id)`;
  - partial cancellation index on `(cancelled_at desc, request_id)`.
- Reuse current request, occurrence, payment, and facility-assignment indexes.
- Queue upserts collapse repeated lifecycle writes.
- `FOR UPDATE SKIP LOCKED` allows safe queue batches.
- Anomaly Center RPC uses keyset pagination by `(last_detected_at, id)`, maximum 100 rows.
- Center metrics read anomalies/profiles, not raw reservation history.
- Detail history is bounded to 90 days and fetched only when opened.
- Baselines are refreshed once nightly and reused by all facility-context rules.
- Use `EXPLAIN (ANALYZE, BUFFERS)` against seeded high-volume fixtures before activation.
- Add monitoring queries for queue age, error count, evaluation duration, anomaly volume by rule, and false-positive rate.

## N. Testing Plan

### Database tests

Add:

- `supabase/tests/reservation_anomaly_engine_test.sql`
- `supabase/tests/reservation_anomaly_risk_test.sql`
- `supabase/tests/reservation_anomaly_rls_test.sql`
- `supabase/tests/reservation_anomaly_lifecycle_test.sql`

Cover:

- Every threshold boundary and rolling-window edge.
- Asia/Manila date boundaries and `[start,end)` overlap semantics.
- Recurring reservations without adverse outcomes.
- Corrected no-shows.
- Late versus timely cancellation.
- Same-facility exclusion regression and cross-facility overlap advisory.
- All four payment rules rejecting internal/payment-exempt records.
- Verified staff remaining internal and excluded from external payment anomalies.
- Deduplication under repeat/concurrent evaluation.
- Correlation dedup across facilities.
- Decay, family caps, success credits, score cap, and risk bands.
- False-positive exact-fingerprint suppression and new-evidence behavior.
- Internal/external lane isolation, assigned/unassigned facility isolation, renter denial, and audit isolation.
- Notification tier uniqueness and recipient scope.
- Queue retry/locking and cron idempotency.

### Flutter tests

Add:

- `test/anomaly_model_test.dart`
- `test/anomalies_screen_test.dart`
- `test/anomaly_detail_test.dart`
- `test/reservation_risk_summary_test.dart`

Cover:

- DTO parsing and unknown-enum fallback.
- Internal/external metrics and filters.
- Desktop 1180px, tablet 900px, and mobile 430px layouts without overflow.
- Light/dark themes.
- Loading, empty, error, stale, permission-denied, observe-mode, and restricted-evidence states.
- Acknowledge/resolve/false-positive validation.
- Reservation-detail risk card navigation.
- Notification deep-link navigation.
- Renter screens never rendering risk/anomaly data.
- Nonblocking overlap warning in the booking sheet.

### Regression

Run:

```text
supabase test db
flutter analyze
flutter test
```

Retain existing payment, cancellation, external-scope, permit, feedback, loyalty, calendar, reservation, and three-role tests.

## O. Migration and Historical Backfill

- All migrations are additive; no destructive table or enum replacement.
- Backfill attendance timestamps from the latest matching `reservation_event` only when the current lifecycle stage is terminal and metadata is null.
- Backfill cancellation timestamps/reasons from unambiguous `cancel` events; leave ambiguous rows null rather than guessing.
- Backfill payment terminal codes only for exact existing reasons:
  - “Down payment deadline missed”;
  - “Remaining balance deadline missed”.
- Exclude `legacy_financial_state` records from payment anomaly backfill.
- Build facility baselines before contextual evaluation.
- Run `backfill_reservation_anomalies(dry_run=true, notify=false)` and compare counts by lane/rule/facility.
- Run bounded real backfill with notifications disabled.
- Existing five reservations should create no negative-outcome alerts.
- Deploy Flutter only after all read/action RPCs exist.
- Keep contextual rules in observe mode until at least 30 baseline occurrences per facility and 60–90 days of observations are reviewed.
- Activate contextual rules through an audited rule update, one rule at a time.
- Rollback is operational: disable rules and cron jobs; preserve anomaly/audit history.

## P. Implementation Phases

### Phase 0 — Repository and Schema Verification

- Objective: reconfirm `main`, linked migrations, production counts, and no concurrent schema changes.
- Files/objects: read-only inspection of `README.md`, migrations, Supabase metadata, and git status.
- Steps: rerun migration list, aggregate counts, and schema/RLS queries used for this plan.
- Dependencies/migration: none.
- Risks/edge cases: another migration may land after `20260829100000`; renumber new migrations if required.
- Tests: migration parity and clean worktree.
- Done: local/remote histories match and all exact names remain valid.

### Phase 1 — Attendance and Terminal Outcome Foundation

- Objective: make no-show, correction, late cancellation, and payment expiration reliable.
- Files: migration `20260829110000...`, `lib/model/reservation.dart`, `lib/backend/supabase_service.dart`, `app_state.dart`, `decision_panel.dart`.
- Objects: occurrence/request columns and attendance/cancellation/expiration functions.
- Steps: migrate columns, backfill unambiguous rows, intercept attendance actions, add correction UI/RPC, populate canonical terminal codes.
- Dependencies: Phase 0.
- Risks/edge cases: recurring occurrence correction, parent completed status, loyalty idempotency, cancellation undo.
- Tests: lifecycle pgTAP tests plus existing cancellation/payment/loyalty tests.
- Done: every new terminal outcome has actor/time/reason metadata and corrections are audited.

### Phase 2 — Anomaly Database Foundation

- Objective: create secure persisted rule, anomaly, evidence, baseline, profile, and queue objects.
- Files: migration `20260829120000...`, `reservation_anomaly_rls_test.sql`.
- Objects: all V1 tables, indexes, constraints, RLS, audit/notification extensions.
- Steps: create objects, seed 12 rules/modes, revoke direct writes, implement scoped policies.
- Dependencies: Phase 1.
- Risks/edge cases: Internal Admin’s existing broad audit policy and cross-facility correlation.
- Tests: role/lane/assignment/renter denial tests.
- Done: neither admin can read the other lane or unassigned evidence through tables or joins.

### Phase 3 — Rule Engine and Risk Scoring

- Objective: implement deterministic rule evaluation and exact scoring.
- Files: migration `20260829130000...`, engine/risk SQL tests.
- Objects: evaluator, upsert, baseline, decay, profile, queue, and schedule functions.
- Steps: implement shared bounded-history query, each rule evaluator, per-facility projection, fingerprints, family caps, recovery, and observe mode.
- Dependencies: Phase 2.
- Risks/edge cases: correlated rules, zero-data baselines, timezone boundaries, concurrent workers.
- Tests: every rule threshold, deduplication, decay, score cap, and `SKIP LOCKED`.
- Done: fixtures produce deterministic explanations, evidence, severity, and scores.

### Phase 4 — Lifecycle and Payment Integration

- Objective: enqueue evaluations from every relevant lifecycle change.
- Files: migration `20260829140000...`, lifecycle SQL tests, `booking_sheet.dart`.
- Objects: queue triggers, overlap advisory, replacements for expiration/payment integration.
- Steps: add lightweight triggers; enqueue submission, approval, cancellation, attendance, correction, payment decision, and expiration; add renter overlap warning.
- Dependencies: Phase 3.
- Risks/edge cases: repeated updates, stale payment proofs, trigger recursion, large expiration batches.
- Tests: one logical action creates one pending queue item and no duplicate anomaly.
- Done: negative events become visible within one queue interval without slowing lifecycle transactions.

### Phase 5 — Internal Admin Anomaly Experience

- Objective: provide internal-only monitoring for assigned internal reservations.
- Files: `anomaly.dart`, `anomalies_screen.dart`, `anomaly_detail.dart`, `app_state.dart`, `supabase_service.dart`, routing/navigation files.
- Objects: center/detail/read RPCs.
- Steps: build metrics, filters, pagination, cards/table, detail timeline, and admin actions; hide payment metrics/rules.
- Dependencies: Phase 4.
- Risks/edge cases: cached external data after role change and restricted evidence.
- Tests: internal fixtures, mobile/desktop/dark/error states.
- Done: Internal Admin can review only assigned internal anomalies.

### Phase 6 — External Admin Anomaly Experience

- Objective: add external renter and payment-specific monitoring using the shared UI.
- Files: same shared anomaly files plus external-role widget tests.
- Objects: same RPCs, exercised under external role.
- Steps: enable payment filters/metrics and external copy; validate navigation to external reservations/payments.
- Dependencies: Phase 5.
- Risks/edge cases: verified internal leakage and paid verified staff classification.
- Tests: external assigned/unassigned and internal-lane denial.
- Done: External Admin sees only assigned external anomalies and eligible payment evidence.

### Phase 7 — Reservation Review Risk Integration

- Objective: surface explainable advisory risk during reservation review.
- Files: `risk_summary_card.dart`, `decision_panel.dart`, `app_state.dart`, `supabase_service.dart`.
- Objects: `get_reservation_risk_summary()`.
- Steps: lazy-load selected renter risk, show top reasons and freshness, support deep link, replace hardcoded no-show count.
- Dependencies: Phases 5–6.
- Risks/edge cases: stale queue evaluations and correlation duplication.
- Tests: risk levels, restricted scope, loading/error, no automatic decision changes.
- Done: every scoped reservation review can show an explained score without scanning raw history.

### Phase 8 — Notifications and Audit Integration

- Objective: route high/critical alerts and preserve an immutable scoped action history.
- Files: migration integration logic, `supabase_service.dart`, `app_state.dart`.
- Objects: notification insert helper, anomaly audit helper, notification deep link.
- Steps: generate tiered notifications, add audit events, enforce uniqueness and anomaly audit RLS.
- Dependencies: Phase 7.
- Risks/edge cases: spam, escalation, broad internal audit access.
- Tests: recipient matrix, uniqueness, audit payload/privacy, deep links.
- Done: notifications and audit respect both lane and facility assignment.

### Phase 9 — Historical Backfill and Calibration

- Objective: populate history safely without alert spam.
- Files: `20260829150000_reservation_anomaly_backfill.sql`.
- Objects: dry-run/batched backfill RPC and progress metadata.
- Steps: build baselines, dry-run, compare counts, batch with `notify=false`, inspect observe signals and false-positive candidates.
- Dependencies: Phase 8.
- Risks/edge cases: incomplete historical metadata and accidentally scoring legacy payment records.
- Tests: rerunning backfill is idempotent; ambiguous records remain unclassified.
- Done: existing history is evaluated once with zero duplicate notifications.

### Phase 10 — Testing, Performance, and Hardening

- Objective: validate correctness, security, responsiveness, and query cost before enabling contextual scoring.
- Files: all new SQL/Dart tests; no production behavior changes unless defects are found.
- Objects: query plans, queue/false-positive monitoring queries, rule modes.
- Steps: run full suites, high-volume fixtures, concurrent evaluations, RLS adversarial tests, responsive/dark/accessibility checks, and production dry-run monitoring.
- Dependencies: all prior phases.
- Risks/edge cases: facility skew, queue backlog, overly broad rules.
- Tests: full regression plus explain/analyze benchmarks.
- Done: all suites pass, no cross-domain/assignment leakage exists, queue latency meets target, and only approved rule modes are active.
