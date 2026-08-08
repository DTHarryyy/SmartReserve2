import '../../model/decision_check.dart';
import '../../model/facility.dart';
import '../../model/reservation.dart';

class Conflict {
  const Conflict({
    required this.label,
    required this.requester,
    required this.start,
    required this.end,
  });

  final String label;
  final String requester;
  final String start;
  final String end;

  double get startAt =>
      (int.tryParse(start.split(':').first) ?? 0) +
      (int.tryParse(start.split(':').last) ?? 0) / 60;

  double get endAt =>
      (int.tryParse(end.split(':').first) ?? 0) +
      (int.tryParse(end.split(':').last) ?? 0) / 60;
}

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

  List<Conflict> get conflicts => [
    for (final b in bookings)
      if (b.facility == request.facility &&
          b.date == request.date &&
          b.overlaps(request.startAt, request.endAt))
        Conflict(
          label: b.label,
          requester: b.requester,
          start: b.start,
          end: b.end,
        ),
    for (final r in otherRequests)
      if (r.id != request.id &&
          r.status == RequestStatus.approved &&
          r.facility == request.facility &&
          r.date == request.date &&
          r.startAt < request.endAt &&
          request.startAt < r.endAt)
        Conflict(
          label: r.purpose,
          requester: r.requester,
          start: r.start,
          end: r.end,
        ),
  ];

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

  List<DecisionCheck> get checks {
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
        label: 'Hours & days',
        value: !withinOperatingHours
            ? 'Outside operating hours (${f?.hours ?? '—'}).'
            : (!withinAvailableDays
                  ? '$weekday is not an available day (${f?.days ?? '—'}).'
                  : 'Inside ${f?.hours ?? '—'} on ${f?.days ?? '—'}.'),
        outcome: withinOperatingHours && withinAvailableDays
            ? CheckOutcome.pass
            : CheckOutcome.warn,
      ),
      DecisionCheck(
        label: 'Conflicts',
        value: hasConflict
            ? 'Collides with ${conflicts.length} confirmed '
                  '${conflicts.length == 1 ? 'booking' : 'bookings'}.'
            : 'The slot is free.',
        outcome: hasConflict ? CheckOutcome.fail : CheckOutcome.pass,
      ),
    ];
  }

  CheckSummary get summary => CheckSummary.of(
    checks,
    clear: 'Every check passed. Approving creates no conflict.',
    caution: 'Approvable, but read the flagged checks first.',
    blocked: hasConflict
        ? 'Approving as requested would double-book the facility.'
        : 'This cannot be approved as requested.',
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
    final h = hours.floor();
    final m = ((hours - h) * 60).round();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}
