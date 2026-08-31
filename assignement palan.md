# Replace facility-specific administrator assignments with global lane administration

## 1. Confirmed target behavior

### Booking eligibility

| Requester | Required administrator coverage | Facility assignment required? |
|---|---|---|
| Verified student, faculty, or staff | At least one active `internal_admin` anywhere in the system | No |k
| Guest, unverified, or pending user | At least one active `external_admin` anywhere in the system | No |

A facility remains subject to its own status, public-listing flag, opening hours, booking rules, and classification (`shared`, `internal`, or `external`). Administrator assignment must not make a facility available or unavailable.

### Administrator capabilities

- Any active administrator can edit every facility, including photos, rates, amenities, payment methods, terms, and configuration.
- Any active `internal_admin` can read and act on every internal-lane reservation.
- Any active `external_admin` can read and act on every external-lane reservation.
- An administrator cannot read or act on the other lane’s reservation, payment, attachment, permit, or anomaly evidence.
- Every active matching-lane admin receives each new reservation notification. The existing reservation version/idempotency controls remain responsible for preventing conflicting actions.
- If a lane has zero active admins, booking is blocked safely and explicitly. The app must say which administrator type is missing.

## 2. Database migration design

Create one new, forward-only migration after `20260830110000_global_lane_reservation_routing.sql`, for example:

`supabase/migrations/20260830120000_global_admin_authorization.sql`

Do not modify prior migrations, since production may have already recorded them.

### 2.1 Archive and disable legacy assignments

1. Create `facility_admin_assignment_archive` with:

   - A generated archive ID.
   - Original `facility_id`, `admin_id`, `assignment_role`, `assigned_by`, and `created_at`.
   - `archived_at timestamptz not null default now()`.
   - `archived_by uuid null`, set to the migration actor only if available.
   - A unique key covering the original assignment key plus archival batch, preventing accidental duplicate imports.

2. Copy every current row from `facility_admin_assignments` into the archive in a single transaction.

3. Lock down the archive:

   - Enable RLS.
   - Revoke direct access from `anon` and `authenticated`.
   - Do not create UI or client RPC access; it is service-role/audit evidence only.

4. Retire assignment behavior without dropping the legacy table in this release:

   - Drop the `facilities_assign_creator` trigger so newly created facilities never get a creator assignment.
   - Drop the assignment read policy.
   - Revoke execution of `facility_assignment_directory`, `set_facility_admin_assignment`, and `remove_facility_admin_assignment`.
   - Remove those RPCs only in the later cleanup migration, avoiding dependency-order failures during the first rollout.
   - Keep `facility_admin_assignments` read-only and unused for 30 days after production validation, then drop it and the obsolete assignment-role functions in a dedicated cleanup migration.

### 2.2 Establish the canonical authorization predicates

Keep the existing reservation-lane rules:

- `requester_admin_lane(user_id)` maps verified campus users to `internal`; every other requester maps to `external`.
- `admin_lane(admin_id)` maps an active internal/external admin profile to its lane.
- `has_active_admin_in_lane(lane)` remains the sole test for whether a requester lane has coverage.

Replace assignment-dependent authorization with these exact semantics:

- `can_manage_facility(facility_id, admin_id)`:
  - Returns true only when `facility_id` exists and `admin_id` belongs to an active `internal_admin` or `external_admin`.
  - Does not query `facility_admin_assignments`.
  - Preserves the current two-argument signature so existing policies/RPCs can be migrated safely.

- `can_manage_reservation(request_id, admin_id)`:
  - Returns true only when the request exists, the admin profile is active, and `admin_lane(admin_id) = reservation_requests.admin_lane`.
  - Does not require `can_manage_facility`.

- Remove `is_facility_owner` and `has_facility_admin_lane` only after every caller has been migrated.
  - Replace facility owner checks with active-administrator checks.
  - Replace facility/lane coverage checks with `has_active_admin_in_lane(requester_admin_lane())`.

This separation is important: facility configuration is global for active admins, while sensitive reservation data remains lane-scoped.

### 2.3 Rebuild access and availability RPCs

Replace `my_facility_access()` with a backward-compatible result that retains existing fields used by older clients and adds explicit availability metadata:

```text
facility_id uuid
can_manage boolean
supports_internal boolean
supports_external boolean
bookable boolean
booking_unavailability_code text null
```

Remove `assignment_role` from the result.

Rules:

- `can_manage` is true for any active administrator.
- `supports_internal` means the facility classification accepts internal requesters; it does not mean an internal administrator is assigned.
- `supports_external` means the facility classification accepts external requesters; it does not mean an external administrator is assigned.
- For requester accounts, `bookable` is true only when the facility is active, public, unarchived, supports the requester lane, and `has_active_admin_in_lane(requester_lane)` is true.
- `booking_unavailability_code` is one of:
  - `no_active_internal_admin`
  - `no_active_external_admin`
  - `facility_not_available_for_account_type`
  - `facility_inactive`
  - `null` when bookable

Redeclare both `get_reservation_quote` and `submit_reservation_v2` in the same migration so they enforce this exact global-lane condition server-side. Do not rely on the Flutter UI for authorization.

### 2.4 Update all assignment-derived policies and RPCs

Audit every use of `can_manage_facility`, `can_manage_reservation`, `is_facility_owner`, and `has_facility_admin_lane`, then redeclare affected policies/functions in the new migration.

| Area | Required authorization after migration |
|---|---|
| Facility rows, photos, rates, amenities, payment methods, and terms | Any active administrator |
| Facility activity and facility audit entries | Any active administrator |
| Reservation request, occurrence, event, attachment, payment, payment proof, permit, and acceptance records | Requester, or active admin in the matching reservation lane |
| Reservation actions, approve/bump actions, payment decisions, permits, attendance, cancellation, and terminal outcomes | Active admin in the matching reservation lane |
| Calendar, availability, quote, and submission | Requester’s classification plus an active global admin in the requester lane |
| Reports and operational metrics | Active admin, filtered to their reservation lane wherever reservation data is included |
| Feedback and feedback notifications | Remove facility-assignment predicates; preserve the existing role/lane policy, using active matching-lane recipients for reservation-specific notifications |
| Reservation anomalies and risk profiles | Preserve anomaly lane isolation; remove only the facility-assignment requirement from matching-lane visibility |
| Storage policies | Global active-admin access for facility photos; matching-lane reservation access for reservation files, payment proofs, and permits |

Include `NOTIFY pgrst, 'reload schema'` at the end of the migration.

## 3. Flutter and backend implementation

### 3.1 Backend contract and models

Update `SmartReserveCoreBackend`, `SupabaseService`, `BackendFacility`, and `Facility`:

- Remove:
  - `FacilityAssignmentOption`
  - `facilityAssignmentDirectory`
  - `setFacilityAssignment`
  - `removeFacilityAssignment`
  - `assignmentRole`
- Add `FacilityBookingBlockReason`, backed by the RPC’s `booking_unavailability_code`.
- Keep lane-support information as requester eligibility, not administrator coverage; rename model/UI fields if needed to prevent future “admin assigned” wording.
- Parse the new access fields defensively so the client shows a recoverable refresh error if the app is temporarily used with an old backend schema.

### 3.2 Remove the assignment UI

Update `facility_configuration_dialog.dart` and related state/service calls:

- Delete the “Administrators” section.
- Delete owner/manager labels, assignment buttons, assignment removal buttons, and assignment-loading state.
- Remove messages such as “You are not assigned to manage this facility.”
- Replace edit gating with “active administrator required.”
- Retain all normal facility configuration fields and save behavior.

### 3.3 Correct the requester experience

Update the catalogue card, preview/detail dialog, booking sheet, calendar, and assistant:

- Replace generic `Unavailable · no administrator` with:
  - `Unavailable · no active internal administrator`
  - `Unavailable · no active external administrator`
- Add a consistent explanation: “Reservations are temporarily unavailable because no active administrator is available for your account type. Contact support.”
- Keep disabled Reserve controls for truly unstaffed lanes; do not hide facilities.
- Remove “Internal admin assigned” and “External admin assigned” from facility details. Replace them with neutral eligibility text:
  - “Available to verified campus users”
  - “Available to guests and non-verified users”
- Ensure the booking sheet shows the server’s exact error if the last matching admin is deactivated after the catalogue loaded.

## 4. Test implementation

### 4.1 PostgreSQL/pgtap tests

Add a dedicated global-admin authorization test suite and update obsolete assignment tests.

Required cases:

1. A facility with zero assignment rows is bookable for a verified requester when one active internal admin exists.
2. The same unassigned facility is bookable for a guest/non-verified requester when one active external admin exists.
3. Internal and external requesters receive the expected `admin_lane` snapshot when submitting.
4. Two active internal admins both receive the same internal request notification and can read/action it.
5. Two active external admins both receive the same external request notification and can read/action it.
6. An internal admin cannot read or act on an external reservation; an external admin cannot read or act on an internal reservation.
7. Either active admin can edit an unassigned facility’s settings, rate, amenities, payment method, and photo.
8. Suspension of the last active internal admin makes internal booking unavailable but does not affect external booking when an external admin remains active.
9. Suspension of the last active external admin produces the external no-admin error.
10. Archived and live legacy assignment rows do not change any authorization result.
11. Reservation attachments, payment proofs, permits, feedback, reports, audit records, and anomaly evidence retain requester ownership and matching-lane isolation.
12. Existing optimistic concurrency/idempotency behavior rejects a second conflicting admin decision.

### 4.2 Flutter tests

Update or add widget/unit tests for:

- A zero-assignment facility with active global coverage enables Reserve.
- Internal/external unstaffed reasons map to the correct card, tooltip, preview, booking-sheet, and assistant messages.
- Facility classification still blocks the wrong requester type.
- An admin can open/edit any facility without assignment data.
- The assignment section and assignment RPC methods no longer exist in the rendered admin configuration flow.
- Server-side no-admin errors are displayed after a stale client attempts submission.

## 5. Release procedure and acceptance criteria

### Deployment sequence

1. In a Supabase CLI-enabled CI/deployment environment, record:
   - Applied migration history.
   - Counts of active internal and external admins.
   - Assignment-row count and archive-row count after migration.
   - Facilities currently marked unavailable by requester lane.

2. Apply the database migration first.

3. Immediately run SQL smoke checks using a verified requester, a guest/non-verified requester, one active admin in each lane, and a facility with no assignment records.

4. Release the Flutter client after backend verification.

5. Force/recommend a facility refresh on existing sessions so the old cached “no administrator” state is replaced.

6. Monitor reservation RPC error counts for `no_active_internal_admin` and `no_active_external_admin`; these should only occur when a lane is genuinely unstaffed.

7. After 30 days with no legacy RPC calls or assignment-table dependencies, run the separately reviewed cleanup migration to drop the old assignment table, indexes, and obsolete functions.

### Done criteria

- No active administrator is assigned to a specific facility.
- A facility with zero former assignment rows is reservable whenever the requester’s lane has an active administrator.
- Every active matching-lane admin can process every reservation in that lane.
- All active admins can configure every facility.
- Internal/external reservation data remains isolated.
- A truly empty lane disables booking with an accurate, user-visible explanation.
- Assignment data is archived before final deletion.

## Assumptions locked for this plan

- “No admin assigned to every specific facility” means the assignment system is fully removed, not merely auto-populated.
- Facility classification remains in place and is separate from administrator routing.
- Both active administrator roles may configure all facilities.
- Administrators remain separated by reservation lane for privacy and operational safety.
- Legacy assignment records are retained as service-role audit evidence for 30 days before cleanup.
