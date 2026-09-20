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
booking-audience categories, not roles. In the prototype, public account
registration is disabled. Internal Admins issue named organization
representative accounts directly, with one active representative slot per
account-bearing organization. A representative is always `role = user`, is
assigned to exactly one organization slot, and must change the temporary
password on first sign-in before submitting reservations. Existing personal
campus accounts can still sign in, but they cannot reserve until an Internal
Admin assigns them to an organization slot or explicitly converts them to an
external guest. Internal admins control facilities, verification, accounts,
and audit. External admins share read-only access to all feedback and a
sanitized directory of eligible external clients, while reservation, calendar,
payment, and report operations stay limited to their assigned facilities and
external-lane records.

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
`supabase/migrations` and deploy the Edge Functions. From an authenticated
Supabase CLI environment, link the intended project and run `supabase db push`
before releasing the Flutter client. In particular, the
`20260905110000_auth_session_profile_contract.sql` migration must be applied:
it installs `get_my_session_profile`, the authenticated login-profile contract.
If that RPC is absent, valid credentials are accepted and then safely rejected
because the application cannot establish the account's authorization profile.

Before releasing any client that depends on a new database RPC, verify that
the linked project has every local migration:

```powershell
./tool/verify_supabase_migrations.ps1
```

The command fails when either side has a migration that the other does not.
Database migrations must be deployed before the corresponding Flutter client;
the app intentionally does not submit reduced reservation records through an
older RPC when `submit_reservation_v3` is unavailable.
The facilities migration
creates the table, RLS policies, realtime registration and public catalogue
photo bucket, then imports the six original catalogue records once without
fake photos.

The `manage-users` function must be deployed before releasing a client that
uses live account management. Keep `invite-admin` deployed during that rollout
for compatibility with older clients.

### Auth and prototype account setup

Public email sign-up creates only external guest accounts for outside renters
and paying customers. Only active Internal Admins can create campus
organization representative accounts, and they hand off the generated
temporary password directly to the named account holder. No confirmation,
invite, password-reset, or OTP email is required for prototype organization
account provisioning.

### Prototype bootstrap administrator

`20260905111500_ensure_prototype_internal_admin.sql` intentionally restores
the documented Internal Admin account and its prototype password so private
demonstrations can be recovered after a reset or an incomplete deployment. It
must never be applied to a public production project: replace it with
environment-controlled administrator provisioning and rotate the prototype
credential before any public release.

The initial setup target is nine account-bearing organization units:

- CICS: six specialized organizations
- CICS: one minor organization
- COLSC: one organization
- Dean Office: one account

CICS and COLSC are hierarchy containers only and should be created without
representative accounts. Each account-bearing organization automatically gets
one active representative slot. To replace a representative, transfer or remove
the current holder first; do not create a shared department password.

For local Supabase, enable public email sign-up so outside renters and paying
customers can create an external guest account. Campus organization
representative accounts must still be provisioned by an Internal Admin:

```toml
[auth]
enable_signup = true

[auth.email]
enable_signup = true
enable_confirmations = false
```

For the hosted project, enable public email sign-up and keep email
confirmation disabled only when an immediate sign-in is desired. Public
registrations are created as `external_guest` accounts; campus organization
accounts continue to be created through the Admin API.

Password reset, organization representative invitations, and administrator
invitation resend require custom SMTP before user testing or release.
Operational reservation, payment, and anomaly notices stay in-app for this
release.

If email confirmation is enabled for production, configure and verify custom
SMTP first. The app will ask a new renter to confirm their email before signing
in.

For production, configure SMTP in Supabase Auth settings, not in committed
files:

- SMTP host and port
- SMTP username and password
- Sender email
- Sender name: `SmartReserve`

Set the deployed app URLs before enabling representative invitations:

- Confirmation redirect URL: the app’s email-confirmation route
- Password reset: SmartReserve verifies the six-digit `{{ .Token }}` recovery
  code in-app, so no redirect URL is needed for that flow.
- Invitation redirect URL: the app’s invite/onboarding route, also passed to
  Edge Functions as `INVITE_REDIRECT_TO`
- Password recovery Edge Function fallback: `RECOVERY_REDIRECT_TO`

After deployment, verify email delivery with a throwaway invite: confirm the
message sender, link domain, redirect target, and one-time invitation behavior.
Never commit SMTP passwords, API keys, production sender credentials, or
Supabase service-role keys.

For production sign-up confirmation, restore a verified sender and the existing
`{{ .Token }}` confirmation template so Supabase can send six-digit OTP emails.

Feedback sentiment analysis is an asynchronous administrator-only analytics
feature. Deploy `feedback-sentiment` with `SENTIMENT_ENABLED=false`, then set
these Supabase Edge Function secrets before enabling it:

```bash
supabase secrets set GROQ_API_KEY=...
supabase secrets set SENTIMENT_PROVIDER=groq
supabase secrets set SENTIMENT_MODEL=openai/gpt-oss-20b
supabase secrets set SENTIMENT_ANALYSIS_VERSION=1
supabase secrets set SENTIMENT_WORKER_KEY=...
supabase secrets set SENTIMENT_ENABLED=false
```

Store `smartreserve_function_url` and `smartreserve_sentiment_worker_key` in
Supabase Vault for the scheduled Cron call. The worker sends only written
feedback text to Groq, never ratings, identities, reservation metadata,
payment data or loyalty data. Enable Groq Zero Data Retention and complete the
institutional privacy review before setting `SENTIMENT_ENABLED=true`.
Feedback submission remains valid if the worker, provider or schedule is
disabled. Historical feedback can be queued later through the bounded
backfill RPC after the new-feedback path has been observed.

### The reservation assistant

The in-app assistant answers reservation, payment, permit, availability,
equipment and policy questions. Most of it never touches a model: a
deterministic parser and a rule layer in the Flutter client resolve the common
questions outright — what you have booked, what you owe, when it is due, why a
permit is held up, which facility fits 200 people — and a knowledge base in
Postgres answers policy. That path costs nothing and works offline of any
provider.

A cloud model is consulted only for a message the parser cannot classify: loose
Taglish, an ambiguous reference, a phrasing no rule covers.

The model never computes anything it could get wrong. Amounts and timestamps
are formatted in Postgres and the edge function before it sees them, and
availability arrives as a list of bookable windows from
`assistant_facility_free_slots` — never as occupied windows for it to subtract,
which is a calculation whose plausible answers are indistinguishable from its
correct ones. Policy text is retrieved from `assistant_knowledge_base` and sent
with the first request rather than waiting for the model to ask for it, which
halves the cost of the commonest class of question.

`assistant-chat` deploys with `ASSISTANT_ENABLED=false`; set these secrets
before enabling it:

```bash
supabase secrets set ASSISTANT_LLM_PROVIDER=openai
supabase secrets set OPENAI_API_KEY=...
supabase secrets set ASSISTANT_MODEL=gpt-4o-mini
supabase secrets set ASSISTANT_MAX_COMPLETION_TOKENS=300
supabase secrets set ASSISTANT_MAX_INPUT_TOKENS=3000
supabase secrets set ASSISTANT_PROVIDER_TIMEOUT_MS=15000
supabase secrets set ASSISTANT_RATE_LIMIT_PER_HOUR=30
supabase secrets set ASSISTANT_KB_VERSION=1
supabase secrets set ASSISTANT_ENABLED=false
```

`ASSISTANT_KB_VERSION` is part of every cache key. Bump it after editing
`assistant_knowledge_base` so cached answers that quoted the old wording are
invalidated rather than served on. Only answers built purely from policy are
ever cached, and the pricing audience is part of the key — an answer that
touched any user-scoped tool is never stored.

**What the assistant transmits, and what it does not.** This is a wider data
class than the sentiment worker above, which sends only feedback text, so it is
stated separately rather than folded into that commitment. When a question
escalates, the model may receive: the user's message, the last six chat turns,
reservation references and facility names, schedule times, peso amounts already
formatted, lifecycle and payment statuses, permit blocker reasons, and policy
text from the knowledge base. It never receives: full names, email addresses,
student or employee numbers, addresses, contact numbers, payment reference
numbers, proof-of-payment images, signatures, permit PDFs, or any identifier
belonging to another account.

That boundary is code, not policy. Every tool result passes through
`redactForProvider` in `supabase/functions/assistant-chat/contract.ts`, and
`contract_test.ts` asserts that no redacted field can survive a projection.
Enable OpenAI Zero Data Retention and complete a fresh institutional privacy
review — covering this wider data class, not the sentiment worker's — before
setting `ASSISTANT_ENABLED=true`.

Identity comes from the verified JWT and nothing else. Every tool read runs
through a Supabase client carrying the caller's own token, so row-level
security decides what comes back; the service-role key is used only for
telemetry and rate-limit rows and is never passed to a tool handler. The model
cannot run SQL, cannot reach a table directly, and cannot write anything: it
may only propose a booking or a cancellation, which the app then applies
through its existing confirm-card path after an explicit tap.

Spend is visible in `assistant_llm_requests` — tokens, estimated cost, latency
and outcome per request, with no message text. Cost is priced against the model
that actually served the turn, so changing `ASSISTANT_MODEL` does not quietly
keep reporting the old model's bill. Rows with `outcome = 'fallback'` are the
backlog for new deterministic rules, grouped by `resolved_intent`, which is how
model usage falls over time rather than grows. The assistant keeps working with
`ASSISTANT_ENABLED=false`, with the function undeployed, or with the provider
down; it simply answers from rules alone.

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
