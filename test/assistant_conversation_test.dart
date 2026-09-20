import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/assistant/assistant_controller.dart';
import 'package:smartreserve/model/payment.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/util/campus_calendar.dart';

/// End-to-end cover for the conversations the assistant must hold without ever
/// calling a model. These go through `send()` rather than the parser so the
/// wiring -- scoping, the reference frame, the rendered cards -- is exercised
/// too, not just intent detection.
///
/// The seeded demo account carries only two zero-price reservations, which
/// would let the money and cancellation assertions pass without ever running.
/// These fixtures give those paths something real to work on.
ReservationRequest _request({
  required String id,
  required String facility,
  required AppState state,
  ReservationLifecycleStatus lifecycle =
      ReservationLifecycleStatus.awaitingPayment,
  int total = 0,
  int verified = 0,
  int downPaymentCentavos = 0,
  DateTime? startsAt,
  DateTime? balanceDueAt,
  String bookingState = 'booked',
}) {
  final start = startsAt ?? campusNow().add(const Duration(days: 7));
  final end = start.add(const Duration(hours: 2));
  return ReservationRequest(
    id: id,
    facility: facility,
    building: 'Test Building',
    room: 'T-01',
    capacity: 40,
    requester: state.userAccount.name,
    requesterId: state.userAccount.id,
    role: 'Guest',
    org: 'Outside renter',
    purpose: 'Assistant test fixture',
    date: formatCampusDate(start),
    start: '08:00',
    end: '10:00',
    heads: 10,
    submitted: 'today',
    urgent: false,
    attachments: 0,
    noShows: 0,
    status: RequestStatus.approved,
    lifecycleStatus: lifecycle,
    totalAmountCentavos: total,
    requiredDownPaymentCentavos: downPaymentCentavos,
    balanceDueAt: balanceDueAt ?? start.subtract(const Duration(days: 3)),
    paymentDueAt: campusNow().add(const Duration(days: 1)),
    occurrences: [
      ReservationOccurrence(
        id: '$id-occ',
        startsAt: start,
        endsAt: end,
        bookingState: bookingState,
      ),
    ],
    paymentTransactions: [
      if (verified > 0)
        PaymentTransaction(
          id: '$id-pay',
          requestId: id,
          payerId: state.userAccount.id,
          purpose: PaymentPurpose.downPayment,
          amountCentavos: verified,
          referenceNumber: 'REF$id',
          proofPath: 'proof/$id',
          status: PaymentDecisionStatus.verified,
          submittedAt: campusNow(),
        ),
    ],
  );
}

void main() {
  late AppState state;
  late AssistantController controller;

  setUp(() {
    state = AppState();
    controller = AssistantController();
    controller.messages.clear();
  });

  String transcript() =>
      controller.messages.map((message) => message.text).join('\n');

  List<AssistantMessage> assistantSaid() => [
    for (final message in controller.messages)
      if (message.speaker == AssistantSpeaker.assistant) message,
  ];

  group('facility recommendation', () {
    test('"suggest a facility for 200 people" answers with ranked cards', () async {
      await controller.send('can you suggest a facility for 200 people', state);

      final cards = assistantSaid().where(
        (message) => message.kind == AssistantMessageKind.facilities,
      );
      expect(cards, isNotEmpty, reason: 'the answer must be actionable');

      for (final facility in cards.first.facilities) {
        expect(
          facility.capacity,
          greaterThanOrEqualTo(200),
          reason: 'a room that cannot hold the party is not a suggestion',
        );
      }
      // The list the user just saw is what "the second one" now refers to.
      expect(controller.frame.facilityIds, isNotEmpty);
    });

    test('"recommend an office with aircon" never invents a match', () async {
      await controller.send(
        'recommend a facility where i want a office type haved a aircon',
        state,
      );

      final cards = assistantSaid()
          .where((message) => message.kind == AssistantMessageKind.facilities)
          .toList();

      if (cards.isEmpty) {
        // No Office exists in this dataset; saying so is the correct answer.
        expect(transcript().toLowerCase(), contains('match'));
      } else {
        expect(cards.first.facilities, isNotEmpty);
      }
    });

    test('an unknown amenity word is reported rather than silently dropped', () async {
      await controller.send('suggest a room with a jacuzzi', state);
      expect(transcript().toLowerCase(), contains('jacuzzi'));
    });
  });

  group('reservations', () {
    test('listing records what ordinals refer to', () async {
      await controller.send('What reservations do I have?', state);

      if (state.myRequests.isEmpty) {
        expect(transcript(), contains('Nothing booked yet'));
      } else {
        expect(
          controller.frame.reservationIds,
          state.myRequests.map((request) => request.id).toList(),
        );
      }
    });

    test('a facility-scoped status question does not answer about another room',
        () async {
      await controller.send(
        'how is the status of my reservation in basketball court',
        state,
      );

      final shown = assistantSaid()
          .where((message) => message.kind == AssistantMessageKind.reservations)
          .expand((message) => message.reservations)
          .toList();

      for (final request in shown) {
        expect(
          state.myRequests.map((r) => r.id),
          contains(request.id),
          reason: 'only the signed-in account\'s records may be shown',
        );
      }
    });
  });

  group('cancellation', () {
    void seedOneCancellable() {
      state.requests
        ..clear()
        ..addAll([
          _request(
            id: 'future',
            facility: 'University Auditorium',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
          ),
          // Already started, so the rules must keep it out of reach.
          _request(
            id: 'started',
            facility: 'Reading Hall B',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
            startsAt: campusNow().subtract(const Duration(hours: 3)),
          ),
        ]);
    }

    test('"cancel this specific booking" names one and waits for a tap', () async {
      seedOneCancellable();
      final before = [
        for (final request in state.myRequests) request.lifecycleStatus,
      ];

      await controller.send('cancel this specific booking to me', state);

      expect(transcript(), contains('University Auditorium'));
      expect(controller.frame.focusReservationId, 'future');
      expect(
        [for (final request in state.myRequests) request.lifecycleStatus],
        before,
        reason: 'cancellation requires an explicit tap on the card',
      );
    });

    test('only cancellable reservations are offered', () async {
      seedOneCancellable();
      await controller.send('cancel my reservation', state);

      final offered = assistantSaid()
          .where((message) => message.kind == AssistantMessageKind.reservations)
          .expand((message) => message.reservations)
          .toList();

      expect(offered, isNotEmpty);
      for (final request in offered) {
        expect(
          state.canCancelReservation(request),
          isTrue,
          reason: '${request.facility} cannot be cancelled',
        );
      }
      expect(
        offered.map((request) => request.id),
        isNot(contains('started')),
        reason: 'a reservation already under way is never offered',
      );
    });

    test('two cancellable rows produce a question, not a pick', () async {
      state.requests
        ..clear()
        ..addAll([
          _request(
            id: 'one',
            facility: 'University Auditorium',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
          ),
          _request(
            id: 'two',
            facility: 'Reading Hall B',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
          ),
        ]);

      await controller.send('cancel this specific booking to me', state);
      expect(transcript(), contains('Which one'));
      expect(controller.frame.reservationIds, hasLength(2));
    });

    test('a facility name narrows a cancellation to one row', () async {
      state.requests
        ..clear()
        ..addAll([
          _request(
            id: 'aud',
            facility: 'University Auditorium',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
          ),
          _request(
            id: 'hall',
            facility: 'Reading Hall B',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
          ),
        ]);

      await controller.send('cancel my reading hall booking', state);
      expect(controller.frame.focusReservationId, 'hall');
    });

    test('nothing cancellable says so plainly', () async {
      state.requests
        ..clear()
        ..add(
          _request(
            id: 'done',
            facility: 'University Auditorium',
            state: state,
            lifecycle: ReservationLifecycleStatus.completed,
            startsAt: campusNow().subtract(const Duration(days: 4)),
          ),
        );

      await controller.send('cancel my reservation', state);
      expect(transcript().toLowerCase(), contains('cancelled right now'));
    });
  });

  group('payment', () {
    /// One unpaid reservation, so "how much do I owe" has an unambiguous
    /// target and a real number to get right.
    void seedUnpaid() {
      state.requests
        ..clear()
        ..add(
          _request(
            id: 'unpaid-1',
            facility: 'University Auditorium',
            state: state,
            total: 350000,
            downPaymentCentavos: 175000,
          ),
        );
    }

    test('the stated amount is the record\'s, to the centavo', () async {
      seedUnpaid();
      await controller.send('how much do I still need to pay', state);

      expect(
        transcript(),
        contains('₱3500'),
        reason: 'outstanding is 350000 centavos',
      );
      expect(controller.frame.focusReservationId, 'unpaid-1');
    });

    test('a partial payment is subtracted, not restated as the total', () async {
      state.requests
        ..clear()
        ..add(
          _request(
            id: 'partial-1',
            facility: 'University Auditorium',
            state: state,
            total: 350000,
            verified: 175000,
            downPaymentCentavos: 175000,
          ),
        );

      await controller.send('how much do I owe', state);
      expect(transcript(), contains('₱1750'));
      expect(transcript(), isNot(contains('₱3500')));
    });

    test('a fully paid reservation reports nothing owing', () async {
      state.requests
        ..clear()
        ..add(
          _request(
            id: 'paid-1',
            facility: 'University Auditorium',
            state: state,
            lifecycle: ReservationLifecycleStatus.confirmed,
            total: 200000,
            verified: 200000,
          ),
        );

      await controller.send('how much do I owe', state);
      expect(transcript().toLowerCase(), contains('fully paid'));
    });

    test('the deadline is reported alongside the amount, in one turn', () async {
      seedUnpaid();
      await controller.send('how much do I owe and when is it due', state);

      expect(transcript(), contains('₱3500'));
      expect(transcript().toLowerCase(), anyOf(contains('due'), contains('overdue')));
    });

    test('an overdue balance is flagged as overdue', () async {
      state.requests
        ..clear()
        ..add(
          _request(
            id: 'late-1',
            facility: 'University Auditorium',
            state: state,
            total: 100000,
            startsAt: campusNow().add(const Duration(days: 2)),
            balanceDueAt: campusNow().subtract(const Duration(days: 1)),
          ),
        );

      await controller.send('when is my payment deadline', state);
      expect(transcript().toLowerCase(), contains('overdue'));
    });

    test('amounts are never invented when nothing is booked', () async {
      state.requests.clear();
      await controller.send('how much do I still need to pay', state);

      expect(transcript(), contains('Nothing booked yet'));
      expect(
        transcript(),
        isNot(contains('₱')),
        reason: 'no record means no amount, not a plausible one',
      );
    });

    test('two unpaid reservations produce a question, not a guess', () async {
      state.requests
        ..clear()
        ..addAll([
          _request(
            id: 'a',
            facility: 'University Auditorium',
            state: state,
            total: 100000,
          ),
          _request(
            id: 'b',
            facility: 'Reading Hall B',
            state: state,
            total: 900000,
          ),
        ]);

      await controller.send('how much do I owe', state);
      expect(transcript(), contains('Which one'));
      expect(
        transcript(),
        isNot(contains('₱')),
        reason: 'no amount may be stated until the target is known',
      );
    });

    test('an ordinal follow-up resolves to the row that was shown', () async {
      state.requests
        ..clear()
        ..addAll([
          _request(
            id: 'first',
            facility: 'University Auditorium',
            state: state,
            total: 100000,
          ),
          _request(
            id: 'second',
            facility: 'Reading Hall B',
            state: state,
            total: 900000,
          ),
        ]);

      await controller.send('Show my upcoming reservations', state);
      expect(controller.frame.reservationIds, ['first', 'second']);

      controller.messages.clear();
      await controller.send('How much do I owe for the second one?', state);

      expect(transcript(), contains('₱9000'));
      expect(controller.frame.focusReservationId, 'second');
    });
  });

  group('scope', () {
    test('out-of-scope subjects are refused without inventing an answer', () async {
      await controller.send('what is my grade in math', state);
      expect(transcript(), contains('outside what I do'));
    });
  });

  group('policy', () {
    test('external renter rules are answered from the app\'s own policy', () async {
      await controller.send('what are the rules for external renters', state);
      final said = transcript().toLowerCase();
      expect(said, contains('down payment'));
      expect(said, contains('balance'));
    });

    test('cancellation policy states the real rule, with no invented fee', () async {
      await controller.send('what is the cancellation policy', state);
      final said = transcript().toLowerCase();
      expect(said, contains('no cancellation fee'));
    });
  });

  group('permits', () {
    test('permit requirements are explained without touching a record', () async {
      await controller.send('what are the requirements for a permit', state);
      final said = transcript().toLowerCase();
      expect(said, contains('approved'));
      expect(said, contains('signature'));
    });
  });

  test('a booking request still opens the facility picker', () async {
    // The existing slot-filling flow must be untouched by the new intents.
    await controller.send('Book a room', state);
    expect(controller.stage, AssistantStage.needFacility);
  });

  group('follow-up references after a facility list', () {
    // Browsing facilities is the commonest thing a user does before saying
    // "the second one". Several paths used to render the list without telling
    // the reference frame, so the follow-up had nothing to resolve against and
    // the assistant asked which room it had just finished listing.

    test('browsing facilities records what ordinals refer to', () async {
      await controller.send('what facilities are available?', state);

      final listed = [
        for (final message in controller.messages)
          if (message.kind == AssistantMessageKind.facilities) message,
      ];
      expect(listed, isNotEmpty, reason: 'the question must answer with a list');
      expect(
        controller.frame.facilityIds,
        isNotEmpty,
        reason: 'a list the user can point at must be pointable at',
      );
      expect(
        controller.frame.facilityIds.first,
        listed.last.facilities.first.id,
        reason: 'display order is the order an ordinal counts in',
      );
    });

    test('an ordinal resolves to the facility that was shown', () async {
      await controller.send('what facilities are available?', state);
      final shown = [
        for (final message in controller.messages)
          if (message.kind == AssistantMessageKind.facilities) message,
      ].last.facilities;
      if (shown.length < 2) return;

      expect(
        controller.frame.resolveFacility(ordinal: 2).id,
        shown[1].id,
      );
    });
  });
}
