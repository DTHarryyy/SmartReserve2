import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/reservations/conflict_engine.dart';
import 'package:smartreserve/features/reservations/reservation_checks.dart';
import 'package:smartreserve/model/decision_check.dart';
import 'package:smartreserve/model/reservation.dart';

ReservationRequest _request({
  required String id,
  required String facility,
  String? facilityId,
  required String date,
  required String start,
  required String end,
  RequestStatus status = RequestStatus.pending,
}) => ReservationRequest(
  id: id,
  facility: facility,
  facilityId: facilityId,
  building: 'Building',
  room: 'Room',
  capacity: 40,
  requester: 'Requester $id',
  role: 'User',
  org: 'Org',
  purpose: 'Purpose $id.',
  date: date,
  start: start,
  end: end,
  heads: 10,
  submitted: '1 day ago',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: status,
);

void main() {
  group('holdsAgainst', () {
    test(
      'a request never collides with the booking its own approval created',
      () {
        final request = _request(
          id: 'req-1',
          facility: 'University Auditorium',
          facilityId: 'fac-1',
          date: 'Tue 18 Aug',
          start: '07:30',
          end: '09:30',
          status: RequestStatus.approved,
        );
        final ownBooking = Booking.fromLabels(
          id: 'occ-1',
          facility: 'University Auditorium',
          facilityId: 'fac-1',
          date: 'Tue 18 Aug',
          start: '07:30',
          end: '09:30',
          label: request.purpose,
          requester: request.requester,
          sourceRequestId: 'req-1',
        );

        final holds = holdsAgainst(
          request: request,
          bookings: [ownBooking],
          otherRequests: [request],
        );
        expect(holds, isEmpty);

        final assessment = ReservationAssessment(
          request: request,
          facility: null,
          bookings: [ownBooking],
          otherRequests: [request],
        );
        expect(assessment.hasConflict, isFalse);
        final conflictsRow = assessment.checks.firstWhere(
          (c) => c.label == 'Conflicts',
        );
        expect(conflictsRow.outcome, CheckOutcome.pass);
        expect(conflictsRow.value, 'Holds 07:30–09:30 — confirmed.');
      },
    );

    test(
      'one genuine clash is counted once, not twice as booking and request',
      () {
        final mine = _request(
          id: 'mine',
          facility: 'Room A',
          date: 'Tue 18 Aug',
          start: '09:00',
          end: '11:00',
        );
        final theirs = _request(
          id: 'theirs',
          facility: 'Room A',
          date: 'Tue 18 Aug',
          start: '10:00',
          end: '12:00',
          status: RequestStatus.approved,
        );
        final theirBooking = Booking.fromLabels(
          id: 'occ-theirs',
          facility: 'Room A',
          date: 'Tue 18 Aug',
          start: '10:00',
          end: '12:00',
          label: theirs.purpose,
          requester: theirs.requester,
          sourceRequestId: 'theirs',
        );

        final holds = holdsAgainst(
          request: mine,
          bookings: [theirBooking],
          otherRequests: [mine, theirs],
        );
        expect(holds.length, 1);
        expect(holds.single.sourceRequestId, 'theirs');
      },
    );

    test('adjacent slots on the same day do not clash', () {
      final request = _request(
        id: 'req',
        facility: 'Room A',
        date: 'Tue 18 Aug',
        start: '10:00',
        end: '12:00',
      );
      final earlier = Booking.fromLabels(
        id: 'earlier',
        facility: 'Room A',
        date: 'Tue 18 Aug',
        start: '08:00',
        end: '10:00',
        label: 'Earlier',
        requester: 'Someone',
      );
      expect(
        holdsAgainst(request: request, bookings: [earlier], otherRequests: []),
        isEmpty,
      );
    });

    test('the same month and day in a different year does not clash', () {
      final request = _request(
        id: 'req',
        facility: 'Room A',
        date: 'Tue 18 Aug',
        start: '09:00',
        end: '11:00',
      );
      final nextYear = Booking(
        id: 'next-year',
        facility: 'Room A',
        startsAt: DateTime.utc(2027, 8, 18, 9, 0),
        endsAt: DateTime.utc(2027, 8, 18, 11, 0),
        label: 'Same digits, different year',
        requester: 'Someone',
      );
      expect(
        holdsAgainst(request: request, bookings: [nextYear], otherRequests: []),
        isEmpty,
      );
    });

    test('facility ids win over a shared display name', () {
      final request = _request(
        id: 'req',
        facility: 'Shared Name',
        facilityId: 'fac-X',
        date: 'Tue 18 Aug',
        start: '09:00',
        end: '11:00',
      );
      final otherRoomSameName = Booking.fromLabels(
        id: 'other-room',
        facility: 'Shared Name',
        facilityId: 'fac-Y',
        date: 'Tue 18 Aug',
        start: '09:00',
        end: '11:00',
        label: 'Different room, same display name',
        requester: 'Someone',
      );
      expect(
        holdsAgainst(
          request: request,
          bookings: [otherRoomSameName],
          otherRequests: [],
        ),
        isEmpty,
        reason: 'different facility ids must not cross-clash',
      );

      final sameRoomRenamed = Booking.fromLabels(
        id: 'same-room',
        facility: 'A Renamed Room',
        facilityId: 'fac-X',
        date: 'Tue 18 Aug',
        start: '09:00',
        end: '11:00',
        label: 'Same room under an old label',
        requester: 'Someone',
      );
      expect(
        holdsAgainst(
          request: request,
          bookings: [sameRoomRenamed],
          otherRequests: [],
        ),
        hasLength(1),
        reason: 'the id still identifies it as the same room',
      );
    });
  });
}
