# SmartReserve

Facility reservation system for CSU Aparri, implemented from the Claude Design
project *Campus facility mapping interface*
(`SmartReserve Add Facility.dc.html`).

Every surface in that design is built: the admin console, the auth and
onboarding flow, the user-facing app, and the design-notes reference page.
Authentication, campus-verification submissions and decisions, facilities,
facility photos, user administration, reservations, booking occurrences,
private supporting files, reservation events, and in-app notifications are
backed by Supabase. Reporting reads the live reservation data; non-reservation
prototype audit entries remain in memory.

## Layout

```
lib/
  main.dart                    app entry, theme, AppScope
  app/
    app_state.dart             app state backed by Supabase repositories
    app_scope.dart             InheritedNotifier over it
    app_shell.dart             nav, header, overlays, global accelerators
    app_view.dart              the surfaces
  theme/sr_tokens.dart         colour, type, elevation, motion, breakpoints
  data/                        campus reference data and the seeded records
  model/                       facility · reservation · verification ·
                               account · audit entry · decision check
  util/geo.dart                haversine, boundary test, nudge, geocode
  widgets/                     shared controls, tables, queues, notices
  features/
    add_facility/              the form, the map, the pin
    facilities/                catalogue, detail dialog, archive
    reservations/              decision queue, checks, conflicts, recurring
                               series and lifecycle
    calendar/                  centralized month · week · day admin calendar
    verifications/             campus-claim queue, document viewer
    users/                     accounts, invite, role and suspension
    audit/                     append-only log with diffs and revert
    reports/                   utilisation, demand, performance, data quality
    auth/                      the nine-card onboarding flow
    student/                   user browse, reservations, account, booking
    profile/ · notes/
```

## The flows that connect

- **Onboarding → the registrar's queue.** A campus claim files a real
  submission; the pending card then shows whatever the registrar actually
  decides, including the reason, verbatim.
- **Verifying → held requests.** A request made while verification is pending
  is server-quoted and held, not refused. Approval removes the charge and
  routes it to the internal queue; rejection releases it to the paid external
  queue.
- **Every decision → the audit log.** Approvals, declines, bumps, role changes,
  suspensions, invitations, pin moves. A revert appends a new entry; nothing is
  ever edited or deleted.
- **Reports → Add Facility.** A data-quality row deep-links into the offending
  record in edit mode.

## Authorization model

SmartReserve has exactly three account roles: `user`, `internal_admin`, and
`external_admin`. Student, faculty, staff, and outside-user selections are
verification claim categories, not roles. Only a verified active `user`
reserves without payment. Internal admins control facilities, verification,
accounts, and audit. External admins share read-only access to all feedback
and a sanitized directory of eligible external clients, while reservation,
calendar, payment, and report operations stay limited to their assigned
facilities and external-lane records.

Reservation prices are calculated in Supabase from duration and facility
capacity. Client-provided amounts are ignored, so free access cannot be gained
by modifying the application request.

## Notable behaviour

- **Six required items** on Add Facility, tracked in a progress strip whose
  chips jump to the section that needs work.
- **Pinning** by click, drag, 1 m nudge pad, pasted coordinates, map search or
  GPS. Every map action has a non-spatial equivalent.
- **Advisories** dock under the map — outside the boundary, over 90 m from the
  building, loose accuracy. They warn and flag for review; they never block.
- **Centralized calendar.** The month, week and day views show every
  reservation occurrence across all facilities, including weekends and every
  date in a recurring series. Facility, status and text filters narrow the
  operational view; a selected event opens its request in the decision queue.
- **Conflict detection** on selection, not on submit, with a computed
  next-free-slot offer and an approve-and-bump path that requires a reason.
- **Recurring series** are one decision, not twelve: every date is expanded and
  checked up front, and the registrar either books the lot or books the free
  dates and hands the clashing ones back for a new time.
- **After the decision** — check-in and completion, plus a quiet "no decision
  needed, mark expired" for requests that have gone stale.
- **Per-record activity.** A facility and a reservation each carry the log
  filtered to themselves, because "what changed here" is a different question
  from "what changed lately".
- **Shift-click** in either queue selects the range from the last row ticked.
- **Guardrails**: nobody changes their own role, the last internal admin cannot
  be demoted, and bulk actions refuse to run over anything carrying a warning.
- **Undo windows** instead of confirm dialogs for anything cheap to reverse.
- **Responsive**: two rails at ≥1180 px, a 260 px sticky map strip and a
  collapsing queue panel at 768–1179 px, single column with a full-screen
  crosshair pinning sheet below that.

## Running

```bash
flutter pub get
flutter run -d chrome --dart-define=SUPABASE_URL=https://tyniwgrvfxkfzhbiufib.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_8TRsZIH1OEeEGkOrJ0y7oQ_g_IRxcr8
flutter test
flutter analyze
```

Before running against a new Supabase project, apply the migrations in
`supabase/migrations` and deploy the Edge Functions. The facilities migration
creates the table, RLS policies, realtime registration and public catalogue
photo bucket, then imports the six original catalogue records once without
fake photos.

The `manage-users` function must be deployed before releasing a client that
uses live account management. Keep `invite-admin` deployed during that rollout
for compatibility with older clients.

The final bootstrap migration creates `admin@csu.edu.ph` as the initial active
internal administrator when that Auth email does not already exist. Its
initial password is `admin123`; change it immediately through the password
recovery flow after first sign-in. If the email already exists, the migration
promotes its profile without overwriting its existing password.

Map tiles come from OpenStreetMap, Esri World Imagery and CARTO, so the app
needs network access. When tiles fail the map shows an explicit offline panel
with retry and manual coordinate entry.

## Notes for the next change

- `reverseGeocode` in `lib/util/geo.dart` is a deterministic stand-in for a
  geocoding service. Swap the body; no caller changes.
- Facilities are always loaded from Supabase in production. `AppState` can
  still opt into seeded facility fixtures for isolated tests.
- The onboarding OTP accepts a demo code, surfaced on the card itself.
- Production uses authenticated Supabase profiles and role-based routing.
  Seeded accounts and reservations are retained only by explicit demo/test
  `AppState` instances.
- `seriesDemoBookings` in `lib/data/seed_reservations.dart` is the one piece of
  data not in the design source. The design's `BOOKINGS` stop in July while the
  only recurring request runs to October, so without those two rows the
  "approve with exceptions" path could never fire. Delete them and the series
  card correctly reports twelve free dates.
- The centralized calendar uses `campusToday` for demo data and CSU Aparri's
  current date in production. It pages across months, weeks and all seven days.
