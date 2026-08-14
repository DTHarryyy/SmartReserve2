/// Pure availability math for the student booking assistant: given a
/// facility's rules (open hours/days, buffer, max duration, advance window)
/// and a list of busy windows for one day, work out what is still free and
/// whether a specific slot would actually be accepted by the server.
///
/// Deliberately not a generalisation of
/// `ReservationAssessment.nextFreeSlot` (`lib/features/reservations/
/// reservation_checks.dart`) — that helper is single-day, string-hour based,
/// takes a `ReservationRequest`, and ignores buffer/max-duration/advance
/// rules, so reusing it here would mean bolting all of that onto the admin
/// decision panel. This is a fresh, narrow module instead.
library;

import 'dart:math' as math;

import '../../model/facility.dart';

/// A busy interval on one calendar day, in campus wall-clock hours
/// (e.g. 9.5 == 09:30). Carries no identity — see
/// `supabase/migrations/20260814120000_facility_busy_windows.sql` for why:
/// the assistant only ever needs to know a window is occupied, not by whom.
class BusyWindow {
  const BusyWindow(this.startHour, this.endHour);
  final double startHour;
  final double endHour;
}

class FreeSlot {
  const FreeSlot({
    required this.day,
    required this.startHour,
    required this.endHour,
  });
  final DateTime day;
  final double startHour;
  final double endHour;

  String get label => '${formatClockHour(startHour)}–${formatClockHour(endHour)}';
}

enum SlotIssue {
  closedDay,
  outsideHours,
  tooLong,
  inPast,
  beyondAdvance,
  overCapacity,
  clash,
  facilityUnavailable,
  zeroDuration,
}

class SlotVerdict {
  const SlotVerdict(this.issues);
  final List<SlotIssue> issues;
  bool get ok => issues.isEmpty;
}

/// `'yyyy-mm-dd'` — the shared key shape for busy-window maps, so
/// `AppState`, the controller, and tests all bucket the same way.
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

String formatClockHour(double hours) {
  final h = hours.floor();
  final m = ((hours - h) * 60).round();
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

double _ceilToStep(double hour, double step) => (hour / step).ceil() * step;

/// The exclusion constraint `reservation_occurrences_no_overlap` compares
/// `blocked_window && blocked_window`, where each window is padded by the
/// facility's buffer on both sides: `(cs-b, ce+b) ∩ (bs-b, be+b) ≠ ∅` ⟺
/// `cs < be+2b && bs-2b < ce`. That is exactly a raw-candidate overlap test
/// against a busy window inflated by `2 × buffer` on both sides — so that is
/// what this does, to stay provably identical to what the server will do.
List<BusyWindow> _inflate(List<BusyWindow> busy, int bufferMinutes) {
  final bufferHours = (2 * bufferMinutes) / 60;
  return [
    for (final b in busy)
      BusyWindow(b.startHour - bufferHours, b.endHour + bufferHours),
  ];
}

/// Free `durationHours`-long slots on [day], snapped to a 30-minute grid
/// (matching `booking_sheet._times`), honouring open hours/days, buffer, and
/// (when [nowWall] falls on the same day) not offering a slot in the past.
List<FreeSlot> freeSlotsForDay({
  required Facility facility,
  required DateTime day,
  required List<BusyWindow> busy,
  required double durationHours,
  DateTime? nowWall,
  int limit = 6,
  double step = 0.5,
}) {
  if (durationHours <= 0) return const [];
  if (!facility.opensOn(day)) return const [];

  final open = facility.openHour.toDouble();
  final close = facility.closeHour.toDouble();
  var lo = open;
  if (nowWall != null && _isSameDay(day, nowWall)) {
    final nowHour = nowWall.hour + nowWall.minute / 60;
    lo = math.max(lo, _ceilToStep(nowHour, step));
  }

  final inflated = _inflate(busy, facility.bookingBufferMinutes);
  final slots = <FreeSlot>[];
  var start = lo;
  while (start + durationHours <= close && slots.length < limit) {
    final end = start + durationHours;
    final clashes = inflated.any((b) => b.startHour < end && start < b.endHour);
    if (!clashes) {
      slots.add(FreeSlot(day: day, startHour: start, endHour: end));
    }
    start += step;
  }
  return slots;
}

/// Every reason [startHour, endHour) on [day] for [heads] people would be
/// rejected — client-side, so the assistant can say why *before* submitting
/// and pre-empt the matching server error (durations/windows), while
/// [SlotIssue.clash] pre-empts the server's exclusion-constraint race.
SlotVerdict checkSlot({
  required Facility facility,
  required DateTime day,
  required double startHour,
  required double endHour,
  required int heads,
  required List<BusyWindow> busy,
  required DateTime nowWall,
}) {
  final issues = <SlotIssue>[];

  if (endHour <= startHour) {
    issues.add(SlotIssue.zeroDuration);
  }
  if (facility.state == FacilityState.maintenance) {
    issues.add(SlotIssue.facilityUnavailable);
  }
  if (!facility.opensOn(day)) {
    issues.add(SlotIssue.closedDay);
  }
  if (startHour < facility.openHour || endHour > facility.closeHour) {
    issues.add(SlotIssue.outsideHours);
  }
  final durationMinutes = ((endHour - startHour) * 60).round();
  if (durationMinutes > facility.maxDurationMinutes) {
    issues.add(SlotIssue.tooLong);
  }
  if (heads > facility.capacity) {
    issues.add(SlotIssue.overCapacity);
  }

  final today = DateTime(nowWall.year, nowWall.month, nowWall.day);
  final dayOnly = DateTime(day.year, day.month, day.day);
  if (dayOnly.isBefore(today)) {
    issues.add(SlotIssue.inPast);
  } else if (_isSameDay(dayOnly, today)) {
    final nowHour = nowWall.hour + nowWall.minute / 60;
    if (startHour < nowHour) issues.add(SlotIssue.inPast);
  }

  final advanceLimit = today.add(Duration(days: facility.advanceBookingDays));
  if (dayOnly.isAfter(advanceLimit)) {
    issues.add(SlotIssue.beyondAdvance);
  }

  if (endHour > startHour) {
    final inflated = _inflate(busy, facility.bookingBufferMinutes);
    final clashes = inflated.any(
      (b) => b.startHour < endHour && startHour < b.endHour,
    );
    if (clashes) issues.add(SlotIssue.clash);
  }

  return SlotVerdict(issues);
}

/// The next day (starting from [from], inclusive) [facility] is open and
/// has room for a [duration]-hour slot, consulting [byDay] (keyed by
/// [dayKey]) for that day's busy windows. Returns null if nothing turns up
/// within [lookahead] days.
DateTime? nextOpenDayWithSpace(
  Facility facility,
  DateTime from,
  double duration,
  Map<String, List<BusyWindow>> byDay, {
  int lookahead = 14,
}) {
  var day = DateTime(from.year, from.month, from.day);
  for (var i = 0; i < lookahead; i++) {
    if (facility.opensOn(day)) {
      final busy = byDay[dayKey(day)] ?? const [];
      final slots = freeSlotsForDay(
        facility: facility,
        day: day,
        busy: busy,
        durationHours: duration,
        limit: 1,
      );
      if (slots.isNotEmpty) return day;
    }
    day = day.add(const Duration(days: 1));
  }
  return null;
}
