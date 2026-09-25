import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/util/campus_calendar.dart';

ReservationRequest _request({
  required DateTime startsAt,
  required DateTime endsAt,
  String bookingState = 'booked',
  BookingStage stage = BookingStage.booked,
  int totalAmountCentavos = 0,
}) => ReservationRequest(
  id: 'reschedule-request',
  requesterId: 'u1',
  facility: 'Computer Laboratory 1',
  facilityId: 'f1',
  building: 'CICS',
  room: 'CICS-201',
  capacity: 40,
  requester: 'Jomar Padilla',
  role: 'User',
  org: 'CICS',
  purpose: 'Review session',
  date: formatCampusDate(startsAt),
  slotDay: dayOnly(startsAt),
  start: formatClock(startsAt.hour + startsAt.minute / 60),
  end: formatClock(endsAt.hour + endsAt.minute / 60),
  heads: 10,
  submitted: 'Today',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.approved,
  lifecycleStatus: ReservationLifecycleStatus.confirmed,
  totalAmountCentavos: totalAmountCentavos,
  occurrences: [
    ReservationOccurrence(
      id: 'occurrence-1',
      startsAt: startsAt,
      endsAt: endsAt,
      bookingState: bookingState,
      stage: stage,
    ),
  ],
);

void main() {
  group('requester reschedule', () {
    final now = DateTime(2026, 9, 25, 9);

    test('only an active future occurrence can request a move', () {
      final future = _request(
        startsAt: now.add(const Duration(days: 2)),
        endsAt: now.add(const Duration(days: 2, hours: 2)),
      );
      final started = _request(
        startsAt: now.subtract(const Duration(minutes: 30)),
        endsAt: now.add(const Duration(hours: 1)),
      );
      final checkedIn = _request(
        startsAt: now.add(const Duration(days: 2)),
        endsAt: now.add(const Duration(days: 2, hours: 2)),
        stage: BookingStage.checkedIn,
      );
      final state = AppState();

      expect(
        state.canRequestReservationReschedule(future, now: now),
        isTrue,
      );
      expect(
        state.canRequestReservationReschedule(started, now: now),
        isFalse,
      );
      expect(
        state.canRequestReservationReschedule(checkedIn, now: now),
        isFalse,
      );
    });

    test('demo reschedule releases the old slot for admin reapproval', () async {
      final campusNowValue = campusNow();
      final originalStart = DateTime(
        campusNowValue.year,
        campusNowValue.month,
        campusNowValue.day + 2,
        10,
      );
      final request = _request(
        startsAt: originalStart,
        endsAt: originalStart.add(const Duration(hours: 2)),
      );
      final state = AppState()..requests = [request];
      final newStart = originalStart.add(const Duration(days: 1, hours: 2));

      final moved = await state.requestReservationReschedule(
        request,
        request.occurrences.single,
        startsAt: newStart,
        endsAt: newStart.add(const Duration(hours: 2)),
        reason: 'Class schedule changed',
      );

      expect(moved, isTrue);
      expect(request.status, RequestStatus.pending);
      expect(
        request.lifecycleStatus,
        ReservationLifecycleStatus.pendingApproval,
      );
      expect(request.occurrences.single.bookingState, 'requested');
      expect(request.occurrences.single.startsAt, newStart);
      expect(request.reason, contains('Class schedule changed'));
    });

    test('a payment-free reschedule may choose a new end time', () async {
      final campusNowValue = campusNow();
      final originalStart = DateTime(
        campusNowValue.year,
        campusNowValue.month,
        campusNowValue.day + 2,
        10,
      );
      final request = _request(
        startsAt: originalStart,
        endsAt: originalStart.add(const Duration(hours: 2)),
      );
      final state = AppState()..requests = [request];
      final newStart = originalStart.add(const Duration(days: 1));

      final moved = await state.requestReservationReschedule(
        request,
        request.occurrences.single,
        startsAt: newStart,
        endsAt: newStart.add(const Duration(hours: 3)),
        reason: 'Need another schedule',
      );

      expect(moved, isTrue);
      expect(request.status, RequestStatus.pending);
      expect(request.occurrences.single.startsAt, newStart);
      expect(
        request.occurrences.single.endsAt,
        newStart.add(const Duration(hours: 3)),
      );
    });

    test('reschedule respects the facility maximum duration', () async {
      final campusNowValue = campusNow();
      final originalStart = DateTime(
        campusNowValue.year,
        campusNowValue.month,
        campusNowValue.day + 2,
        10,
      );
      final request = _request(
        startsAt: originalStart,
        endsAt: originalStart.add(const Duration(hours: 2)),
      );
      final state = AppState()..requests = [request];
      final newStart = originalStart.add(const Duration(days: 1));

      final moved = await state.requestReservationReschedule(
        request,
        request.occurrences.single,
        startsAt: newStart,
        endsAt: newStart.add(const Duration(hours: 5)),
        reason: 'Need another schedule',
      );

      expect(moved, isFalse);
      expect(request.status, RequestStatus.approved);
      expect(request.occurrences.single.startsAt, originalStart);
    });
  });
}
