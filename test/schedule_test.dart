import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/reservations/reservation_series.dart';
import 'package:smartreserve/model/audit_entry.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/util/backend_errors.dart';
import 'package:smartreserve/util/campus_calendar.dart';

void main() {
  group('campus dates', () {
    test('a notice-board label round-trips through a real date', () {
      final parsed = parseCampusDate('Tue 28 Jul');
      expect(parsed, DateTime(2026, 7, 28));

      expect(formatCampusDate(parsed!), 'Tue 28 Jul');
    });

    test('a relative timestamp is not a date', () {
      expect(parseCampusDate('3 days ago'), isNull);
      expect(parseCampusDate('Just now'), isNull);
    });

    test('the working week is Monday to Friday', () {
      final week = workingWeekOf(DateTime(2026, 7, 29));
      expect(week.map(formatCampusDate).toList(), [
        'Mon 27 Jul',
        'Tue 28 Jul',
        'Wed 29 Jul',
        'Thu 30 Jul',
        'Fri 31 Jul',
      ]);
    });

    test('a weekend rolls forward rather than showing a dead week', () {
      expect(formatCampusDate(workingWeekOf(campusToday).first), 'Mon 27 Jul');
    });

    test('clock values survive the round trip', () {
      expect(parseClock('13:30'), 13.5);
      expect(formatClock(9.25), '09:15');
    });
  });

  group('bookable slots', () {
    const slots = ['07:00', '07:30', '08:00', '08:30', '09:00'];
    final day = DateTime(2026, 8, 20);

    test('a future day keeps every slot', () {
      final now = DateTime(2026, 8, 19, 15, 0);
      expect(bookableSlots(slots, day, now), slots);
    });

    test('today drops the slots that have already elapsed', () {
      final now = DateTime(2026, 8, 20, 8, 0);
      expect(bookableSlots(slots, day, now), ['08:30', '09:00']);
    });

    test('the slot at the current minute is not offered', () {
      // The submit round-trip would push it into the past, and the backend
      // rejects a start that is not strictly in the future.
      final now = DateTime(2026, 8, 20, 8, 30);
      expect(bookableSlots(slots, day, now), ['09:00']);
    });

    test('nothing is left once the facility has closed for the day', () {
      final now = DateTime(2026, 8, 20, 21, 0);
      expect(bookableSlots(slots, day, now), isEmpty);
    });

    test('a past day yields nothing', () {
      final now = DateTime(2026, 8, 21, 6, 0);
      expect(bookableSlots(slots, day, now), isEmpty);
    });

    test('before opening, today still offers the full day', () {
      final now = DateTime(2026, 8, 20, 5, 0);
      expect(bookableSlots(slots, day, now), slots);
    });
  });

  group('backend error messages', () {
    test('a PostgrestException keeps only the human half', () {
      const raw =
          'PostgrestException(message: Reservation date is outside the '
          'booking window, code: 22023, details: Bad Request, hint: null)';
      expect(
        friendlyBackendMessage(raw),
        'Reservation date is outside the booking window.',
      );
    });

    test('the machine fields never reach the user', () {
      const raw =
          'PostgrestException(message: Sign in required, code: 42501, '
          'details: Bad Request, hint: null)';
      final result = friendlyBackendMessage(raw);
      expect(result, 'Sign in required.');
      expect(result, isNot(contains('code:')));
      expect(result, isNot(contains('hint:')));
      expect(result, isNot(contains(')')));
    });

    test('existing sentence punctuation is left alone', () {
      const raw = 'PostgrestException(message: Try again., code: 500)';
      expect(friendlyBackendMessage(raw), 'Try again.');
    });

    test('a plain error without the wrapper is passed through', () {
      expect(
        friendlyBackendMessage('Connection closed'),
        'Connection closed.',
      );
    });

    test('an unparseable error falls back to something readable', () {
      expect(
        friendlyBackendMessage('PostgrestException(message: , code: 500)'),
        'That request could not be sent. Check the details and try again.',
      );
    });
  });

  group('recurring series', () {
    ReservationSeries seriesFor(AppState state, String id) {
      final request = state.requestById(id)!;
      return ReservationSeries(
        request: request,
        bookings: state.bookings,
        otherRequests: state.requests,
      );
    }

    test('a one-off request has no series at all', () {
      final state = AppState();
      expect(seriesFor(state, 'r1').applies, isFalse);
    });

    test('twelve weekly occurrences expand from the first date', () {
      final series = seriesFor(AppState(), 'r3');
      expect(series.applies, isTrue);
      final labels = [for (final o in series.occurrences) o.label];
      expect(labels.length, 12);
      expect(labels.first, 'Tue 28 Jul');
      expect(labels[1], 'Tue 4 Aug');
      expect(labels.last, 'Tue 13 Oct');
    });

    test('only the dates something already holds are flagged', () {
      final series = seriesFor(AppState(), 'r3');
      expect(
        [for (final o in series.clashing) o.label],
        ['Tue 11 Aug', 'Tue 25 Aug'],
      );
      expect(series.free.length, 10);
      expect(series.clashing.first.note, contains('Faculty grading session'));
    });

    test('approving the whole series books every date', () {
      final state = AppState();
      final before = state.bookings.length;
      final labels = [
        for (final o in seriesFor(state, 'r3').occurrences) o.label,
      ];

      state.approveSeries('r3', labels);

      expect(state.requestById('r3')!.status, RequestStatus.approved);
      expect(state.bookings.length, before + 12);
      expect(state.bookings.where((b) => b.sourceRequestId == 'r3').length, 12);
    });

    test('an approved series does not then collide with itself', () {
      final state = AppState();
      final labels = [
        for (final o in seriesFor(state, 'r3').occurrences) o.label,
      ];
      state.approveSeries('r3', labels);

      expect(seriesFor(state, 'r3').clashing.length, 2);
    });

    test('exceptions book the free dates and hand back the rest', () {
      final state = AppState();
      final series = seriesFor(state, 'r3');
      final before = state.bookings.length;

      state.approveSeriesWithExceptions(
        'r3',
        booked: [for (final o in series.free) o.label],
        excepted: [for (final o in series.clashing) o.label],
      );

      final request = state.requestById('r3')!;
      expect(request.status, RequestStatus.approved);
      expect(state.bookings.length, before + 10);
      expect(request.seriesExceptions, ['Tue 11 Aug', 'Tue 25 Aug']);

      expect(request.reason, contains('Tue 11 Aug'));
    });
  });

  group('lifecycle', () {
    test('a booking steps forward one stage at a time', () {
      final state = AppState();
      state.decideRequest('r1', RequestStatus.approved, announce: false);
      expect(state.requestById('r1')!.stage, BookingStage.booked);

      state.advanceStage('r1', BookingStage.checkedIn);
      expect(state.requestById('r1')!.stage, BookingStage.checkedIn);

      state.advanceStage('r1', BookingStage.completed);
      expect(state.requestById('r1')!.stage, BookingStage.completed);
    });

    test('closing a booking is material; checking in is routine', () {
      final state = AppState();
      state.advanceStage('r7', BookingStage.checkedIn);
      expect(state.audit.first.material, isFalse);

      state.advanceStage('r7', BookingStage.completed);
      expect(state.audit.first.material, isTrue);
      expect(state.audit.first.diff.last, contains('utilisation'));
    });

    test('a request that has waited three days can be expired', () {
      final state = AppState();

      expect(state.canExpire(state.requestById('r1')!), isTrue);
      expect(state.canExpire(state.requestById('r6')!), isFalse);
    });

    test('a decided request can never be expired', () {
      final state = AppState();
      expect(state.canExpire(state.requestById('r7')!), isFalse);
    });

    test('expiring is reversible and says why in the log', () {
      final state = AppState();
      state.expireRequest('r1');

      expect(state.requestById('r1')!.status, RequestStatus.expired);
      expect(state.audit.first.diff.last, contains('No decision was needed'));

      state.toasts.invokeAction();
      expect(state.requestById('r1')!.status, RequestStatus.pending);
    });
  });

  group('per-record activity', () {
    test('a facility sees its own history and nobody else\'s', () {
      final state = AppState();
      final lab = state.facilityNamed('Computer Laboratory 1')!;
      final entries = state.facilityActivity(lab);

      expect(entries.map((e) => e.action), contains('moved the pin for'));

      expect(entries.every((e) => e.kind == AuditKind.facility), isTrue);
    });

    test('a seeded entry survives its facility being renamed', () {
      final state = AppState();
      final lab = state.facilityNamed('Computer Laboratory 1')!;
      final before = state.facilityActivity(lab).length;

      lab.name = 'Networking Laboratory';

      expect(state.facilityActivity(lab).length, before);
    });

    test('a decision lands on the request it decided', () {
      final state = AppState();
      expect(state.requestActivity('r1'), isEmpty);

      state.decideRequest('r1', RequestStatus.approved, announce: false);
      expect(state.requestActivity('r1').length, 1);
      expect(state.requestActivity('r2'), isEmpty);
    });

    test('a seeded decision is reachable from its request', () {
      final state = AppState();
      expect(
        state.requestActivity('r7').single.action,
        'approved the reservation',
      );
    });
  });

  group('range selection', () {
    test('a plain tick selects one row and anchors there', () {
      final state = AppState();
      state.toggleRequestSelection('r1');
      expect(state.selectedRequestIds, {'r1'});
    });

    test('shift-clicking fills in everything between', () {
      final state = AppState();
      final rows = [for (final r in state.visibleRequests) r.id];
      expect(rows.length, greaterThan(3));

      state.toggleRequestSelection(rows.first);
      state.toggleRequestSelection(rows[3], extend: true);

      expect(state.selectedRequestIds, rows.take(4).toSet());
    });

    test('the range works upwards too', () {
      final state = AppState();
      final rows = [for (final r in state.visibleRequests) r.id];

      state.toggleRequestSelection(rows[3]);
      state.toggleRequestSelection(rows.first, extend: true);

      expect(state.selectedRequestIds, rows.take(4).toSet());
    });

    test('shift with no anchor behaves as an ordinary tick', () {
      final state = AppState();
      final rows = [for (final r in state.visibleRequests) r.id];

      state.toggleRequestSelection(rows[2], extend: true);
      expect(state.selectedRequestIds, {rows[2]});
    });

    test('changing tab drops the anchor with the selection', () {
      final state = AppState();
      final rows = [for (final r in state.visibleRequests) r.id];
      state.toggleRequestSelection(rows.first);

      state.setRequestTab(RequestStatus.approved);
      final approved = [for (final r in state.visibleRequests) r.id];
      state.toggleRequestSelection(approved.first, extend: true);

      expect(state.selectedRequestIds, {approved.first});
    });
  });
}
