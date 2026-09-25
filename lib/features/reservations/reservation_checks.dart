import '../../model/decision_check.dart';
import '../../model/facility.dart';
import '../../model/reservation.dart';
import '../../util/campus_calendar.dart';
import 'conflict_engine.dart';

typedef Conflict = Hold;

class ReservationAssessment {
  ReservationAssessment({
    required this.request,
    required this.facility,
    required this.bookings,
    required this.otherRequests,
  });

  final ReservationRequest request;

  final Facility? facility;
  final List<Booking> bookings;

  final List<ReservationRequest> otherRequests;

  late final List<Conflict> conflicts = holdsAgainst(
    request: request,
    bookings: bookings,
    otherRequests: otherRequests,
  );

  late final List<Conflict> holdsThatDay = holdsAgainst(
    request: request,
    bookings: bookings,
    otherRequests: otherRequests,
    overlappingOnly: false,
  );

  bool get hasConflict => conflicts.isNotEmpty;

  String get weekday => request.date.split(' ').first;

  bool get withinAvailableDays {
    final f = facility;
    if (f == null) return true;
    const order = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final index = order.indexOf(weekday);
    if (index < 0) return true;
    if (f.days.contains('–')) {
      final from = order.indexOf(f.days.split('–').first.trim());
      final to = order.indexOf(f.days.split('–').last.trim());
      return from >= 0 && to >= from && index >= from && index <= to;
    }
    return f.days.split(',').map((d) => d.trim()).contains(weekday);
  }

  bool get withinOperatingHours {
    final f = facility;
    if (f == null) return true;
    return request.startAt >= f.openHour && request.endAt <= f.closeHour;
  }

  bool get _decided => !request.isPending;

  bool get _holdsTheSlot => request.status == RequestStatus.approved;

  String get _conflictValue {
    final count = conflicts.length;
    final plural = count == 1 ? 'booking' : 'bookings';
    if (_decided) {
      if (count > 0) {
        return 'Overlaps $count other confirmed $plural — needs attention.';
      }
      return _holdsTheSlot
          ? 'Holds ${formatClockRange(request.start, request.end)} — confirmed.'
          : 'No hold on this slot.';
    }
    return count > 0
        ? 'Collides with $count confirmed $plural.'
        : 'The slot is free.';
  }

  late final List<DecisionCheck> checks = _buildChecks();

  List<DecisionCheck> _buildChecks() {
    final f = facility;
    final headroom = (f?.capacity ?? request.capacity) - request.heads;
    return [
      DecisionCheck(
        label: 'Capacity',
        value: headroom >= 0
            ? '${request.heads} of ${f?.capacity ?? request.capacity} seats · '
                  '$headroom spare.'
            : '${request.heads} people in a '
                  '${f?.capacity ?? request.capacity}-seat room — '
                  '${-headroom} over.',
        outcome: headroom >= 0 ? CheckOutcome.pass : CheckOutcome.fail,
      ),
      DecisionCheck(
        label: 'Facility state',
        value: f == null
            ? 'This facility is no longer in the catalogue.'
            : (f.state == FacilityState.maintenance
                  ? 'Closed for maintenance — bookings are being relocated.'
                  : 'Open and published as ${f.state.label.toLowerCase()}.'),
        outcome: f == null
            ? CheckOutcome.fail
            : (f.state == FacilityState.maintenance
                  ? CheckOutcome.warn
                  : CheckOutcome.pass),
      ),
      DecisionCheck(
        label: 'Requester',
        value: request.noShows == 0
            ? 'No prior no-shows on this account.'
            : '${request.noShows} prior no-show'
                  '${request.noShows == 1 ? '' : 's'} on this account.',
        outcome: request.noShows == 0 ? CheckOutcome.pass : CheckOutcome.warn,
      ),
      DecisionCheck(
        label: 'Punctuality',
        value: request.lateCheckIns == 0
            ? 'No late check-ins on this account.'
            : '${request.lateCheckIns} late check-in'
                  '${request.lateCheckIns == 1 ? '' : 's'} in the last 30 days.',
        outcome: request.lateCheckIns == 0
            ? CheckOutcome.pass
            : CheckOutcome.warn,
      ),
      DecisionCheck(
        label: 'Hours & days',
        value: !withinOperatingHours
            ? 'Outside operating hours (${f?.hoursLabel ?? '—'}).'
            : (!withinAvailableDays
                  ? '$weekday is not an available day (${f?.days ?? '—'}).'
                  : 'Inside ${f?.hoursLabel ?? '—'} on ${f?.days ?? '—'}.'),
        outcome: withinOperatingHours && withinAvailableDays
            ? CheckOutcome.pass
            : CheckOutcome.warn,
      ),
      DecisionCheck(
        label: 'Conflicts',
        value: _conflictValue,
        outcome: hasConflict ? CheckOutcome.fail : CheckOutcome.pass,
      ),
    ];
  }

  late final CheckSummary summary = CheckSummary.of(
    checks,
    clear: _decided
        ? 'Every check passed on this booking.'
        : 'Every check passed. Approving creates no conflict.',
    caution: _decided
        ? 'This booking stands, but read the flagged checks.'
        : 'Approvable, but read the flagged checks first.',
    blocked: hasConflict
        ? (_decided
              ? 'This booking overlaps another confirmed hold.'
              : 'Approving as requested would double-book the facility.')
        : (_decided
              ? 'This booking has a failing check.'
              : 'This cannot be approved as requested.'),
  );

  bool get bulkApprovable =>
      request.isPending && checks.every((c) => !c.blocking);

  ({String start, String end})? get nextFreeSlot {
    final f = facility;
    final duration = request.endAt - request.startAt;
    final open = (f?.openHour ?? dayStartHour).toDouble();
    final close = (f?.closeHour ?? dayEndHour).toDouble();

    for (var start = open; start + duration <= close; start += 0.5) {
      final end = start + duration;
      final clashes = conflicts.any((c) => c.startAt < end && start < c.endAt);
      if (!clashes && start != request.startAt) {
        return (start: _hhmm(start), end: _hhmm(end));
      }
    }
    return null;
  }

  static String _hhmm(double hours) {
    return formatClock(hours);
  }
}
