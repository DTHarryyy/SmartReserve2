import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/assistant/assistant_ai_client.dart';
import 'package:smartreserve/features/assistant/assistant_controller.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/util/campus_calendar.dart';

/// The model may propose a booking or a cancellation. It may never perform
/// one. These tests exist to make that difference impossible to erode: a
/// proposal is an offer rendered as a confirm card, and the write still runs
/// through the paths that carry optimistic concurrency and server-side
/// pricing, after a tap.

class _ProposingAiClient implements AssistantAiClient {
  _ProposingAiClient(this.proposal);

  final Map<String, dynamic>? proposal;
  static const text = 'Here is what I can do.';
  int calls = 0;

  @override
  Future<AssistantAiReply> ask(AssistantAiRequest request) async {
    calls++;
    return AssistantAiReply(text: text, proposal: proposal);
  }
}

ReservationRequest _reservation({
  required String id,
  required AppState state,
  required DateTime startsAt,
  ReservationLifecycleStatus lifecycle = ReservationLifecycleStatus.confirmed,
}) => ReservationRequest(
  id: id,
  facility: 'University Auditorium',
  building: 'Administration Building',
  room: 'ADM-G01',
  capacity: 420,
  requester: state.userAccount.name,
  requesterId: state.userAccount.id,
  role: 'Guest',
  org: 'Outside renter',
  purpose: 'Proposal fixture',
  date: formatCampusDate(startsAt),
  start: '08:00',
  end: '10:00',
  heads: 10,
  submitted: 'today',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.approved,
  lifecycleStatus: lifecycle,
  occurrences: [
    ReservationOccurrence(
      id: '$id-occ',
      startsAt: startsAt,
      endsAt: startsAt.add(const Duration(hours: 2)),
      bookingState: 'booked',
    ),
  ],
);

void main() {
  late AppState state;

  setUp(() => state = AppState());

  const unknownQuestion = 'yung ano kasi doon sa tabi ng hagdan';

  List<ReservationRequest> shown(AssistantController controller) => [
    for (final message in controller.messages)
      if (message.kind == AssistantMessageKind.reservations)
        ...message.reservations,
  ];

  group('cancellation proposals', () {
    test('a valid one surfaces the card and cancels nothing', () async {
      final future = campusNow().add(const Duration(days: 7));
      state.requests
        ..clear()
        ..add(_reservation(id: 'live', state: state, startsAt: future));

      final client = _ProposingAiClient({
        'kind': 'cancellation',
        'reservation_id': 'live',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);

      expect(shown(controller).map((r) => r.id), contains('live'));
      expect(
        state.myRequests.single.lifecycleStatus,
        ReservationLifecycleStatus.confirmed,
        reason: 'a proposal must not change a record',
      );
      expect(
        controller.messages.map((m) => m.text).join(' ').toLowerCase(),
        contains('nothing is cancelled until you do'),
      );
    });

    test('one naming a reservation that cannot be cancelled is not rendered',
        () async {
      // Already under way: the rule says no, and the model does not get a vote.
      state.requests
        ..clear()
        ..add(
          _reservation(
            id: 'started',
            state: state,
            startsAt: campusNow().subtract(const Duration(hours: 2)),
          ),
        );

      final client = _ProposingAiClient({
        'kind': 'cancellation',
        'reservation_id': 'started',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);
      expect(shown(controller), isEmpty);
    });

    test('one naming an unknown reservation is ignored', () async {
      state.requests.clear();

      final client = _ProposingAiClient({
        'kind': 'cancellation',
        'reservation_id': 'someone-elses-booking',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);
      expect(shown(controller), isEmpty);
    });
  });

  group('booking proposals', () {
    test('an illegal slot is refused before it is ever offered', () async {
      final facility = state.bookableFacilities.first;
      // Walk forward to a day the facility is actually open, so the only
      // issue the slot can trip is the closing-time one this test is about.
      var day = campusNow().add(const Duration(days: 3));
      while (!facility.opensOn(day)) {
        day = day.add(const Duration(days: 1));
      }
      final client = _ProposingAiClient({
        'kind': 'booking',
        'facility_id': facility.id,
        // Well past the facility's closing time.
        'day': dayKeyFor(day),
        'start_hour': 22.0,
        'end_hour': 23.0,
        'heads': 10,
        'purpose': 'Late night session',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);

      // The time was the only bad part of the offer: it is dropped and the
      // user lands back at the time question, but the rest of what the model
      // got right -- facility, headcount, purpose -- is not thrown away too.
      expect(controller.stage, AssistantStage.needTime);
      expect(controller.draft.facility, facility);
      expect(controller.draft.heads, 10);
      expect(controller.draft.purpose, 'Late night session');
      expect(controller.draft.startHour, isNull);
    });

    test('an over-capacity proposal is refused', () async {
      final facility = state.bookableFacilities.first;
      // Walk forward to a day the facility is actually open, so the only
      // issue the slot can trip is the capacity one this test is about.
      var day = campusNow().add(const Duration(days: 3));
      while (!facility.opensOn(day)) {
        day = day.add(const Duration(days: 1));
      }
      final client = _ProposingAiClient({
        'kind': 'booking',
        'facility_id': facility.id,
        'day': dayKeyFor(day),
        'start_hour': 8.0,
        'end_hour': 10.0,
        'heads': facility.capacity + 1000,
        'purpose': 'Everyone at once',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);
      expect(controller.stage, isNot(AssistantStage.confirming));
      // Only the headcount was the problem; the rest of the offer survives
      // so the user is not asked to restate the whole booking.
      expect(controller.draft.facility, facility);
      expect(controller.draft.heads, isNull);
    });

    test('an unknown facility is refused', () async {
      final client = _ProposingAiClient({
        'kind': 'booking',
        'facility_id': '11111111-2222-3333-4444-555555555555',
        'day': dayKeyFor(campusNow().add(const Duration(days: 3))),
        'start_hour': 8.0,
        'end_hour': 10.0,
        'heads': 10,
        'purpose': 'Somewhere that does not exist',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);
      expect(controller.draft.facility, isNull);
    });

    test('nothing is ever submitted without an explicit confirm', () async {
      final facility = state.bookableFacilities.first;
      final before = state.myRequests.length;

      final client = _ProposingAiClient({
        'kind': 'booking',
        'facility_id': facility.id,
        'day': dayKeyFor(campusNow().add(const Duration(days: 3))),
        'start_hour': 8.0,
        'end_hour': 10.0,
        'heads': 10,
        'purpose': 'Intramurals practice',
      });
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);

      expect(controller.submitting, isFalse);
      expect(
        state.myRequests.length,
        before,
        reason: 'a proposal never creates a reservation',
      );
      expect(controller.stage, isNot(AssistantStage.submitting));
    });
  });

  group('malformed proposals', () {
    test('an unknown kind is ignored and the answer still lands', () async {
      final client = _ProposingAiClient({'kind': 'delete_everything'});
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);

      expect(controller.messages.any((m) => m.assisted), isTrue);
      expect(shown(controller), isEmpty);
    });

    test('no proposal at all is the ordinary case', () async {
      final client = _ProposingAiClient(null);
      final controller = AssistantController(aiClient: client)
        ..messages.clear();

      await controller.send(unknownQuestion, state);
      expect(controller.messages.any((m) => m.assisted), isTrue);
    });
  });
}

/// The `YYYY-MM-DD` form the proposal channel uses.
String dayKeyFor(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';
