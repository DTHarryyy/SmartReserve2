class DesignNote {
  const DesignNote(this.number, this.title, this.items);

  final String number;
  final String title;
  final List<NoteItem> items;
}

class NoteItem {
  const NoteItem(this.key, this.value);

  final String key;
  final String value;
}

const designNotes = <DesignNote>[
  DesignNote('01', 'UX analysis — what actually goes wrong today', [
    NoteItem(
      'The real job',
      'This is not data entry. The admin is asserting "this room exists, here, '
          'and can be booked." The costly failure is a pin that is 40 m off — a '
          'student walks to the wrong building and blames the system, months '
          'after the form was submitted.',
    ),
    NoteItem(
      'Why forms fail here',
      'A long form treats the map as field #14. The pin then gets whatever '
          'attention is left at the end. So the map is given equal visual weight '
          'and permanent presence: it never scrolls away.',
    ),
    NoteItem(
      'Registrar, not power user',
      'The persona adds one room every few weeks and never memorises the flow. '
          'Everything is on one page with numbered sections and no wizard — '
          'nothing is hidden behind a Next button, so scanning the whole scope '
          'takes one glance.',
    ),
    NoteItem(
      'Cognitive load moves',
      'Reverse geocoding fills seven address fields from the pin. Building '
          'selection pre-centres the map. Reservation rules ship with defaults. '
          'The admin types roughly six things; the system derives the rest.',
    ),
  ]),
  DesignNote('02', 'User journey', [
    NoteItem(
      '1 · Intent',
      'From Facilities, "New facility". Any prior draft is offered for restore '
          'before a single keystroke.',
    ),
    NoteItem(
      '2 · Identify',
      'Name, category, capacity. The live preview on the right starts '
          'resembling the real catalogue card immediately.',
    ),
    NoteItem(
      '3 · Locate coarse',
      'Campus and building. Choosing a mapped building offers to centre the '
          'map — the admin starts near the answer instead of at campus scale.',
    ),
    NoteItem(
      '4 · Pin fine',
      'Click, then drag or nudge in 1 m steps until the pin sits on the '
          'doorway. Lat, lng, accuracy and distance from campus centre update '
          'live.',
    ),
    NoteItem(
      '5 · Verify',
      'Boundary check and building-proximity check run on every pin move. '
          'Satellite view is one tap away for rooftop confirmation.',
    ),
    NoteItem(
      '6 · Enrich',
      'Photos with cover selection, amenities as searchable tokens, '
          'reservation rules.',
    ),
    NoteItem(
      '7 · Commit',
      'Save validates six required items; failures surface inline plus a '
          'persistent bar with a jump-to-issue action. Success confirms what '
          'students will now see.',
    ),
  ]),
  DesignNote('03', 'Information architecture', [
    NoteItem(
      'Left rail',
      'Sequential truth: 01 Facility details · 02 Where it sits · 03 Detected '
          'location · 04 Photos · 05 Amenities · 06 Reservation rules. Required '
          'items are marked and reachable from the progress strip.',
    ),
    NoteItem(
      'Right rail',
      'Verification surface: the map, with a Preview tab that swaps in the '
          'student-facing card. Warnings dock directly beneath the map, next to '
          'their cause.',
    ),
    NoteItem(
      'Grouping rule',
      'Fields the admin knows from memory sit left; anything derived, spatial, '
          'or consequential sits right.',
    ),
    NoteItem(
      'Progressive disclosure',
      'Section 03 stays an empty state until a pin exists, so the form never '
          'shows seven blank address fields.',
    ),
  ]),
  DesignNote('04', 'Interaction & motion', [
    NoteItem(
      'Durations',
      '120–180 ms for state changes, 200–260 ms for entrances, 350 ms for the '
          'progress bar. Easing cubic-bezier(.2,.7,.2,1). Nothing exceeds 300 ms '
          'except the deliberate progress sweep.',
    ),
    NoteItem(
      'Pin feedback',
      'Drop pops in with a scale cue and a one-shot accuracy pulse; the '
          'accuracy circle re-scales with zoom so precision is visible rather '
          'than claimed.',
    ),
    NoteItem(
      'Warnings',
      'Slide-fade in beneath the map, never as a modal — a modal would block '
          'the map the admin needs to fix the problem.',
    ),
    NoteItem(
      'Restraint',
      'No animation on map pan, on typing, or on validation text. Motion is '
          'reserved for things that appear or disappear.',
    ),
  ]),
  DesignNote('05', 'Design system recommendations', [
    NoteItem(
      'Type',
      'IBM Plex Sans for interface, IBM Plex Mono for coordinates, IDs and '
          'measurements. Monospace for numbers is functional: digits align while '
          'a pin is dragged, so change is legible.',
    ),
    NoteItem(
      'Colour',
      'Neutral greys carry the layout; a single institutional blue marks '
          'primary action and derived data. Amber for advisory, red for '
          'blocking, green for verified. No decorative gradients.',
    ),
    NoteItem(
      'Radii & elevation',
      'Radius 8 for controls, 10–13 for surfaces. Two elevation levels only: '
          'resting card and floating map control.',
    ),
    NoteItem(
      'Density',
      'Desktop 12–13 px body with 9–11 px labels; scale the same tokens up one '
          'step for touch, never redraw the layout.',
    ),
  ]),
  DesignNote('06', 'Responsive behaviour', [
    NoteItem(
      'Desktop ≥1180',
      'Two rails side by side; map sticky, always visible.',
    ),
    NoteItem(
      'Tablet 768–1179',
      'Map collapses to a 260 px sticky strip above the form, expandable to '
          'fullscreen for pinning; controls grow to 40 px targets.',
    ),
    NoteItem(
      'Mobile <768',
      'Single column with a sticky bottom bar showing pin status. Pinning '
          'happens in a fullscreen map sheet with a centre-crosshair confirm '
          'pattern, which beats finger-precision tapping. GPS capture is '
          'promoted to the primary action, since a phone user is usually inside '
          'the room.',
    ),
  ]),
  DesignNote('07', 'Accessibility', [
    NoteItem(
      'Not map-only',
      'Every map action has a non-spatial equivalent: coordinate entry, '
          'search-by-address, GPS capture, and 1 m nudge buttons. A '
          'screen-reader user can complete the task without pointing at a map.',
    ),
    NoteItem(
      'Announcements',
      'Pin changes, autosaves and validation results post to a polite live '
          'region. Errors are text plus icon plus position — never colour alone.',
    ),
    NoteItem(
      'Keyboard',
      'Logical tab order down the left rail then into map controls; ⌘K to '
          'search, ⌘S to save, Escape closes overlays and fullscreen. Focus '
          'rings are a 3 px tinted halo, never removed.',
    ),
    NoteItem(
      'Targets & contrast',
      '44 px minimum touch targets on tablet and mobile; body text and label '
          'text meet 4.5:1, non-text UI 3:1.',
    ),
  ]),
  DesignNote('08', 'Reservations — the approval workspace', [
    NoteItem(
      "The admin's real job",
      'Not "review a list" but "clear today\'s queue without creating a '
          'conflict." So the surface is a triage queue, not a table of records. '
          'Default view: Needs decision, oldest first, with age visible — the '
          'registrar should never wonder what is at risk of going stale.',
    ),
    NoteItem(
      'Layout',
      'Mirrors Add Facility: request list left, decision panel right. '
          'Selecting a request loads it on the right with facility, requester, '
          'purpose, headcount vs capacity, attachments, and a day-timeline of '
          'that facility showing the requested block against existing bookings. '
          'Approve or Decline live at the bottom of that panel, always visible.',
    ),
    NoteItem(
      'Lifecycle',
      'Submitted → Needs decision → Approved / Declined / Changes requested → '
          'Checked in → Completed, plus Cancelled (by requester) and Expired (no '
          'decision before the event). Every transition is logged with who, '
          'when, and why; declines and change-requests require a reason, '
          'approvals do not.',
    ),
    NoteItem(
      'Decision aids',
      'The panel answers the questions a registrar asks out loud: does the '
          'group fit the capacity, is the facility in maintenance mode, has this '
          'requester no-showed before, does it fall inside operating hours and '
          'available days, and does it collide with anything. Each is a one-line '
          'check with a pass/warn marker — the same advisory grammar as the map '
          'warnings.',
    ),
    NoteItem(
      'Conflicts',
      'Overlap is detected on selection, not on submit. A colliding request '
          'shows the competing booking inline with three exits: approve and bump '
          'the other (requires reason, notifies both), offer the next free slot '
          'as a change-request, or decline. Double-approval is impossible: the '
          'decision is optimistically locked per request and a second admin sees '
          '"being reviewed by…".',
    ),
    NoteItem(
      'Speed for volume',
      'Multi-select with shift-click, then bulk approve when every selected '
          'request is conflict-free; bulk actions refuse to run if any item '
          'carries a warning. Keyboard: J/K to move, A approve, D decline, Enter '
          'open, all with an undo window of a few seconds rather than a confirm '
          'dialog.',
    ),
    NoteItem(
      'Views',
      'Queue (triage), Calendar (per facility or per building, week and day), '
          'and Timeline (all facilities on one day, for spotting gaps and '
          'clashes). Same data, three lenses; the queue is the default because '
          'it is the only one with a to-do.',
    ),
    NoteItem(
      'Requester experience',
      'Every decision emits one notification with the reason and, on decline, '
          'up to three suggested alternative slots so the requester can '
          're-request in a tap instead of starting over.',
    ),
    NoteItem(
      'Recurring & series',
      'A weekly class booking is one request with N occurrences. Approve the '
          'series, or approve with exceptions where individual dates conflict — '
          'never force the admin to decide fifteen near-identical rows.',
    ),
    NoteItem(
      'Edge cases',
      'Facility switched to maintenance after approval (auto-flag affected '
          'bookings, prompt to relocate); requester cancels while a decision is '
          'open; event starts within the approval window (marked urgent, '
          'promoted to the top); facility deleted with future bookings (blocked '
          'until reassigned); no-show handling via check-in expiry.',
    ),
  ]),
  DesignNote('09', 'Reports — integration plan', [
    NoteItem(
      'Why it exists',
      'Reports are not a dashboard for its own sake. They answer four '
          'questions the university actually asks: which facilities are '
          'underused, where demand exceeds supply, how fast the registrar '
          'decides, and which mapped pins are still unverified. Every chart on '
          'the page must trace back to one of those four.',
    ),
    NoteItem(
      'Where the data comes from',
      'Nothing new is collected. Reservations already carry facility, slot, '
          'headcount, decision, decided-by, timestamps and check-in status; '
          'facilities carry capacity, category, building, amenities and pin '
          'confidence. Reports are a read-only projection of those two tables.',
    ),
    NoteItem(
      'Page structure',
      'A date-range and campus/building scope bar pinned at the top, then four '
          'sections: Utilisation, Demand, Approval performance, and Data '
          'quality. Each section is one headline number, one chart, and a ranked '
          'table that drills into the underlying reservations — never a wall of '
          'tiles.',
    ),
    NoteItem(
      'Utilisation',
      'Booked hours against operating hours per facility, as a ranked '
          'horizontal bar. Sorted worst-first by default, because the actionable '
          'insight is the empty room, not the busy one. Filterable by category '
          'so a lab is compared with labs, not with the gym.',
    ),
    NoteItem(
      'Demand',
      'Declined-for-conflict counts and peak-hour heatmap (day of week × '
          'hour). This is the case for building or converting space, so it needs '
          'to be exportable as-is for a budget memo.',
    ),
    NoteItem(
      'Approval performance',
      'Median time-to-decision, share decided within 48 h, '
          'expired-without-decision count, and a per-admin breakdown. Framed as '
          'service level to requesters, not as staff surveillance — the '
          'per-admin view is visible to the registrar role only.',
    ),
    NoteItem(
      'Data quality — the tie back to mapping',
      'Facilities missing a pin, pins flagged outside the boundary, pins over '
          '90 m from their building, facilities without photos, and student '
          '"wrong location" reports. Each row links straight into Add Facility '
          'in edit mode with the offending field focused, which closes the loop '
          'between reporting a problem and fixing it.',
    ),
    NoteItem(
      'Interaction model',
      'Every chart element is a filter, not a decoration: clicking a bar '
          'scopes the table beneath it; clicking a table row opens the '
          'reservation or facility. Scope changes update the URL so a report '
          'view can be pasted into an email.',
    ),
    NoteItem(
      'Export',
      'CSV for the table under each section, PDF for the whole scoped page '
          'with the range printed in the header. Scheduled monthly email of the '
          'same PDF to the Vice President for Administration — that is how these '
          'numbers actually get used.',
    ),
    NoteItem(
      'Guardrails',
      'No metric without a definition tooltip. No comparison against a period '
          'with incomplete data — show "insufficient data" instead of a '
          'misleading −40%. Zero states are explicit ("no declines this '
          'period"), never a blank chart.',
    ),
  ]),
  DesignNote('10', 'Audit log — integration plan', [
    NoteItem(
      'Why it exists',
      'Two real needs, not compliance theatre: settling disputes ("who moved '
          'this pin", "who approved a booking that clashed") and recovering from '
          'mistakes. A log nobody can act on is dead weight, so every entry '
          'answers who, what, when, from what to what, and why.',
    ),
    NoteItem(
      'What gets recorded',
      'Facility created, edited (field-level before/after), pin moved with '
          'both coordinate pairs and the distance moved, boundary override '
          'confirmed with its reason, status change, images added or removed, '
          'and facility archived. On reservations: submitted, approved, declined '
          'with reason, changes requested, bumped booking with reason, undo, '
          'check-in, expiry. On accounts: role granted or revoked, sign-in from '
          'a new device.',
    ),
    NoteItem(
      'What does not',
      'No keystroke history, no draft autosaves, no page views. Drafts are '
          'private until saved — logging them would chill normal editing and '
          'bury the entries that matter.',
    ),
    NoteItem(
      'Entry anatomy',
      'Actor with role · action verb · target with a link · timestamp with '
          'relative and absolute time · a diff line ("Capacity 30 → 40", "Pin '
          'moved 22 m north-east") · reason where the action required one. One '
          'line by default, expandable to the full diff.',
    ),
    NoteItem(
      'Where it surfaces',
      'Three placements, one data source. Inline "Activity" tab on a facility '
          'and on a reservation — the 90% case, because context is already '
          'there. A global log under Reports for cross-cutting questions. And a '
          'compact "last changed by" line in the facility header.',
    ),
    NoteItem(
      'Filtering',
      'Actor, action type, target type, date range, and a "material changes '
          'only" toggle that hides everything except pin moves, status changes, '
          'capacity edits and overrides.',
    ),
    NoteItem(
      'Reversibility',
      'Where an action is safely reversible — a pin move, a capacity edit, a '
          'decision inside the undo window — the entry carries a Revert action '
          'that writes a new entry rather than erasing the old one. The log is '
          'append-only; nothing is ever edited or deleted, including by admins.',
    ),
    NoteItem(
      'Retention & access',
      'Full detail for 24 months, then summarised to one row per facility per '
          'month. Registrars see facility and reservation entries; only the '
          'system administrator sees account and role entries. Export is CSV '
          'with a signature line naming who exported and when — because an '
          'export of an audit log is itself an auditable act.',
    ),
    NoteItem(
      'Tone',
      'Plain institutional past tense, no jargon: "R. Aguinaldo moved the pin '
          'for Computer Laboratory 2 by 22 m · 14 Jul 2026, 09:12 · reason: '
          'corrected to the doorway."',
    ),
  ]),
  DesignNote('11', 'Roles, onboarding & verification', [
    NoteItem(
      'Three roles',
      'Internal admin (registrar / OSA staff): approves campus verifications, '
          'manages facilities, decides reservations, sees student documents. '
          'External admin: manages non-campus clients — rates, quotes, invoices, '
          'refunds and their bookings — and never sees student or faculty '
          'documents. User: books facilities, in one of two states below.',
    ),
    NoteItem(
      'Two user states',
      'Verified campus member (student or faculty of CSU Aparri) reserves '
          'without payment, subject to approval only. External guest reserves at '
          'the published external rate and pays before the slot is held. The '
          'state is a property of the account, not of each booking, so a user '
          'never has to explain who they are twice.',
    ),
    NoteItem(
      'Onboarding — the one question',
      'After account creation the flow asks a single question: "Are you a '
          'student or faculty of CSU Aparri?" Yes and No lead to visibly '
          'different, honest paths — no dark pattern nudging people to claim '
          'campus status, and the fee difference is stated plainly on that '
          'screen so the choice is informed.',
    ),
    NoteItem(
      'While pending',
      'The account is usable immediately: browse facilities, see the map, '
          'prepare a request. What is held is the confirmation — a request '
          'submitted while pending sits in the queue and is released the moment '
          'verification passes. Nobody stares at a blocked screen, and nobody '
          'gets a free booking before the check is done.',
    ),
    NoteItem(
      'Internal admin — verification queue',
      'Same triage shape as the reservation queue: request list left, document '
          'viewer right. Checks run automatically — does the ID number exist in '
          'the student registry, does the name match the account, is the ID '
          'already claimed by another account, is the document legible and '
          'unexpired. Three outcomes: Approve, Request a better document '
          '(reason, does not reject the person), Reject with reason.',
    ),
    NoteItem(
      'Expiry and change of status',
      'Verification carries an expiry — end of academic year for students, end '
          'of appointment for faculty — with a reminder two weeks out and a '
          'one-tap re-submit. A lapsed member becomes a guest rather than being '
          'locked out, so an expired check never strands someone mid-booking.',
    ),
    NoteItem(
      'Privacy and abuse',
      'Documents are visible only to internal admins, watermarked in the '
          'viewer, never downloadable in bulk, and deleted a set period after a '
          'decision — only the decision, the ID number and the decider are '
          'retained. A rejected user gets one appeal with a new document.',
    ),
    NoteItem(
      'Payment rules',
      'Guest flow: quote at request time, payment authorised on approval and '
          'captured at check-in, automatic refund if the facility goes into '
          'maintenance or the booking is declined. Verified members never see a '
          'payment step at all — no zero-peso invoices, no empty cart.',
    ),
  ]),
  DesignNote('12', 'Authentication & account entry', [
    NoteItem(
      'The corrected sequence',
      'Register → confirm email → the campus question → (verification | '
          'dashboard). The question belongs after registration, not before: an '
          'unauthenticated answer cannot be attached to anything, and asking it '
          'first would make people type their identity twice.',
    ),
    NoteItem(
      'Decided — any email plus OTP',
      'Registration takes any email address and a password; a six-digit OTP '
          'confirms the address; verification comes after. No '
          'institutional-domain shortcut, so every campus claim is settled by a '
          'document and a human. Consequence: the verification queue carries '
          '100% of onboarding, so its throughput is the ceiling on how fast the '
          'system fills.',
    ),
    NoteItem(
      'Validation — admins do not self-register',
      'The sign-up form must produce users only. Internal and external admins '
          'are provisioned or invited by an existing internal admin, accept '
          'through a one-time link, and are forced into two-factor at first '
          'sign-in. A public form that can mint an approver is the most serious '
          'hole in the model as described.',
    ),
    NoteItem(
      'Validation — the question needs a third answer',
      'Student and Faculty are not exhaustive. Non-teaching staff, alumni, and '
          'outside organisations booking the gym all exist today. '
          'Recommendation: Student · Faculty · University staff · None of these '
          '— where staff verify like faculty and "none of these" is the guest '
          'path. Without the third option, staff will pick Faculty and pollute '
          'the queue.',
    ),
    NoteItem(
      'OTP behaviour',
      'Six digits, confirmed before the campus question so the document is '
          'attached to a reachable address. A code rather than a link — it '
          'survives webmail rewriting and works when the phone opens the mail '
          'while the desktop holds the session. Resend after 60 s, valid 15 '
          'minutes, five wrong attempts then a cooldown.',
    ),
    NoteItem(
      'Security baseline',
      'Passphrase of 10+ characters checked against a breached-password list '
          'instead of symbol theatre; rate limit by IP and by account; generic '
          'failure copy that never reveals whether an email exists; sessions '
          'expire in 30 days for users and 12 hours for admins.',
    ),
    NoteItem(
      'States each screen needs',
      'Idle · field-level invalid · submitting · server error · rate-limited · '
          'success. Errors sit under the field they belong to, in plain '
          'institutional English: "That code has expired. Request a new one." '
          'Nothing is disabled without saying why.',
    ),
  ]),
  DesignNote('13', 'User management', [
    NoteItem(
      'What this page is for',
      'Three jobs that have nowhere to live today: finding a specific person '
          'when something goes wrong with their booking, changing what someone '
          'is allowed to do, and bringing a new administrator onto the system.',
    ),
    NoteItem(
      'One list, not four',
      'Students, faculty, staff, guests and admins are all rows in the same '
          'table, separated by filters rather than by tabs. Splitting them into '
          'separate pages would mean guessing which page a name is on.',
    ),
    NoteItem(
      'Actions on a user',
      'Change role (with a written reason, logged) · revoke or re-run '
          'verification · suspend with a reason and an end date, which blocks '
          'new requests but leaves existing approved bookings intact · reset '
          'password by sending a link, never by setting one · and delete, which '
          'is only offered for accounts with no reservation history.',
    ),
    NoteItem(
      'Inviting an administrator',
      'A dialog, not a form page: email, then Internal admin or External admin '
          'as two described options, then an optional note that appears in the '
          'invite email. Invited admins appear in the list immediately as '
          '"Invited — not yet accepted" with resend and revoke actions.',
    ),
    NoteItem(
      'Guardrails on admin creation',
      'Only an internal admin can invite. Two-factor is mandatory at first '
          'sign-in. An invite link is single-use and follows the configured '
          'email-link expiry. '
          'Nobody can change their own role, and the system refuses to remove '
          'the last remaining internal admin — the error explains why rather '
          'than just failing.',
    ),
    NoteItem(
      'Bulk work',
      'Multi-select for the two operations that genuinely recur at scale — '
          'end-of-year verification expiry across a cohort, and suspending '
          'accounts flagged for repeated no-shows. Bulk role changes are '
          'deliberately not offered; privilege changes should be individual and '
          'deliberate.',
    ),
  ]),
  DesignNote('14', 'Edge cases & scale', [
    NoteItem(
      'Outside boundary',
      'Advisory, not a hard block — satellite polygons drift and new annexes '
          'exist before the GIS layer updates. Saving is allowed but the '
          'facility is flagged for review, and the reviewer sees the reason.',
    ),
    NoteItem(
      'Far from building',
      'Compared against the mapped building centroid; over 90 m warns, with a '
          'one-tap snap-to-building correction.',
    ),
    NoteItem(
      'Tiles unavailable',
      'Explicit offline panel with retry and manual coordinate entry, so a bad '
          'campus link does not block the record.',
    ),
    NoteItem(
      'Multi-floor stacking',
      'Several facilities share one footprint. Floor plus room number '
          'disambiguate, and the pin is understood as the entrance, not the '
          'geometric centre.',
    ),
    NoteItem(
      'Scale ahead',
      'Bulk CSV import reusing this validation pipeline; indoor floor-plan '
          'overlays with room polygons; a pin-confidence score surfaced to '
          'reviewers; crowd-sourced corrections from student "wrong location" '
          'reports feeding back into the review queue.',
    ),
  ]),
];
