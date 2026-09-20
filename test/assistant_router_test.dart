import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_nlu.dart';
import 'package:smartreserve/features/assistant/assistant_reference_frame.dart';
import 'package:smartreserve/features/assistant/assistant_router.dart';

final _now = DateTime(2026, 9, 20);

AssistantRoute _route(
  String text, {
  AssistantRouteContext context = const AssistantRouteContext(
    aiAvailable: true,
  ),
}) => routeMessage(parseMessage(text, nowWall: _now), context: context);

AssistantIntent _intent(String text) =>
    parseMessage(text, nowWall: _now).intent;

/// Every phrase here must stay answerable without a model call. A case moving
/// from here to the escalation list is a cost regression, not a refactor, so it
/// is asserted rather than left to observation.
void _expectFree(String text, AssistantIntent expected) {
  final route = _route(text);
  expect(
    route.kind,
    AssistantRouteKind.ruleHandled,
    reason: '"$text" must be answered by rules, not the model',
  );
  expect(route.intent, expected, reason: 'intent for "$text"');
}

void main() {
  group('reservations', () {
    test('listing and status questions stay on the free path', () {
      _expectFree('What reservations do I have?', AssistantIntent.myReservations);
      _expectFree(
        'Show my upcoming reservations',
        AssistantIntent.myReservations,
      );
      _expectFree(
        'What is the status of my reservation?',
        AssistantIntent.reservationStatus,
      );
      _expectFree(
        'how is the status of my reservation in basketball court',
        AssistantIntent.reservationStatus,
      );
      _expectFree('Did my request get approved?', AssistantIntent.reservationStatus);
    });

    test('Taglish status phrasing resolves without the model', () {
      _expectFree(
        'anong status ng booking ko sa gym',
        AssistantIntent.reservationStatus,
      );
    });
  });

  group('cancellation', () {
    test('every cancellation phrasing routes to the cancel handler', () {
      _expectFree('Can I cancel my reservation?', AssistantIntent.cancel);
      _expectFree('cancel this specific booking to me', AssistantIntent.cancel);
      _expectFree('Cancel the second one', AssistantIntent.cancel);
      _expectFree('kanselahin ang reservation ko', AssistantIntent.cancel);
    });

    test('a bare cancel is still an abort, not a cancellation request', () {
      final parsed = parseMessage('cancel', nowWall: _now);
      expect(parsed.abort, isTrue);
      // Aborts must work with the model down, so they never escalate.
      expect(_route('cancel').kind, AssistantRouteKind.ruleHandled);
    });

    test('never mind aborts rather than cancelling a reservation', () {
      expect(parseMessage('never mind', nowWall: _now).abort, isTrue);
    });
  });

  group('facility discovery', () {
    test('the named recommendation phrasings are free', () {
      _expectFree(
        'can you suggest a facility for 200 people',
        AssistantIntent.recommendFacility,
      );
      _expectFree(
        'recommend a facility where i want a office type haved a aircon',
        AssistantIntent.recommendFacility,
      );
    });

    test('recommendation criteria are extracted deterministically', () {
      final capacity = parseMessage(
        'can you suggest a facility for 200 people',
        nowWall: _now,
      );
      expect(capacity.capacity?.min, 200);

      final office = parseMessage(
        'recommend a facility where i want a office type haved a aircon',
        nowWall: _now,
      );
      expect(office.category, 'Office');
      expect(office.amenities, contains('Air Conditioning'));
    });

    test('ordinary browsing and availability stay free', () {
      _expectFree(
        'What facilities are available?',
        AssistantIntent.findFacilities,
      );
      _expectFree(
        'Is the gym available tomorrow?',
        AssistantIntent.checkAvailability,
      );
    });

    test('"best time to book" is booking talk, not a recommendation', () {
      expect(
        _intent('what is the best time to book the gym'),
        isNot(AssistantIntent.recommendFacility),
      );
    });
  });

  group('payment', () {
    test('balance and deadline questions are answered from loaded records', () {
      _expectFree(
        'How much do I still need to pay?',
        AssistantIntent.paymentBalance,
      );
      _expectFree('magkano pa bayad ko', AssistantIntent.paymentBalance);
      _expectFree(
        'When is my payment deadline?',
        AssistantIntent.paymentDeadline,
      );
    });

    test('a combined amount-and-deadline question still routes to payment', () {
      final route = _route('how much do I owe and when is it due');
      expect(route.kind, AssistantRouteKind.ruleHandled);
      expect(
        route.intent,
        anyOf(
          AssistantIntent.paymentBalance,
          AssistantIntent.paymentDeadline,
        ),
        reason: 'one handler answers both halves',
      );
    });
  });

  group('permits', () {
    test('ownership language separates status from requirements', () {
      _expectFree('Can I download my permit?', AssistantIntent.permitStatus);
      _expectFree(
        'Why is my permit not available yet?',
        AssistantIntent.permitStatus,
      );
      _expectFree(
        'what are the requirements for a permit',
        AssistantIntent.permitRequirements,
      );
    });
  });

  group('equipment, announcements and policy', () {
    test('topical questions are answered from rules', () {
      _expectFree('What equipment is available?', AssistantIntent.equipment);
      _expectFree('any announcements for me', AssistantIntent.announcements);
      _expectFree(
        'What are the rules for external renters?',
        AssistantIntent.policyFaq,
      );
      _expectFree(
        'What are the requirements for reserving a facility?',
        AssistantIntent.policyFaq,
      );
    });
  });

  group('escalation', () {
    test('unclassifiable phrasing escalates when the model is available', () {
      final route = _route('yung ano kasi doon sa tabi ng hagdan');
      expect(route.kind, AssistantRouteKind.escalate);
      expect(route.reason, EscalationReason.unknownIntent);
    });

    test('with the model unavailable, nothing escalates', () {
      final route = _route(
        'yung ano kasi doon sa tabi ng hagdan',
        context: const AssistantRouteContext(aiAvailable: false),
      );
      expect(route.kind, AssistantRouteKind.ruleHandled);
      expect(route.intent, AssistantIntent.unknown);
    });
  });

  group('booking flow', () {
    const inFlow = AssistantRouteContext(
      inBookingFlow: true,
      aiAvailable: true,
    );

    test('a parseable stage reply never costs a model call', () {
      final route = routeMessage(
        parseMessage('tomorrow 2-4pm', nowWall: _now),
        context: const AssistantRouteContext(
          inBookingFlow: true,
          stageAccepted: true,
          aiAvailable: true,
        ),
      );
      expect(route.kind, AssistantRouteKind.ruleHandled);
    });

    test('an unparseable stage reply escalates once', () {
      final route = routeMessage(
        parseMessage('sa makalawa siguro tanghali', nowWall: _now),
        context: inFlow,
      );
      expect(route.kind, AssistantRouteKind.escalate);
      expect(route.reason, EscalationReason.unparsedBookingSlot);
    });

    test('the loop guard falls back to the deterministic question', () {
      final route = routeMessage(
        parseMessage('sa makalawa siguro tanghali', nowWall: _now),
        context: const AssistantRouteContext(
          inBookingFlow: true,
          aiAvailable: true,
          assistsUsedForStage: maxAssistsPerStage,
        ),
      );
      expect(route.kind, AssistantRouteKind.ruleHandled);
      expect(route.intent, AssistantIntent.book);
    });
  });

  group('out of scope', () {
    test('non-reservation subjects are refused without a model call', () {
      for (final text in [
        'what is my grade',
        'how do I enroll',
        'reset my password',
        'how much is tuition',
      ]) {
        expect(
          _route(text).kind,
          AssistantRouteKind.outOfScope,
          reason: '"$text" is outside the assistant',
        );
      }
    });

    test('an in-scope cue rescues a message that mentions a blocked word', () {
      expect(
        _route('can my professor book a room').kind,
        isNot(AssistantRouteKind.outOfScope),
      );
    });
  });

  group('reference frame integration', () {
    test('ordinals resolve against what was last shown', () {
      final frame = AssistantReferenceFrame()
        ..noteReservations(['r1', 'r2', 'r3']);
      final parsed = parseMessage(
        'How much do I owe for the second one?',
        nowWall: _now,
      );
      expect(parsed.ordinal, 2);
      expect(frame.resolveReservation(ordinal: parsed.ordinal).id, 'r2');
      expect(
        routeMessage(
          parsed,
          context: AssistantRouteContext(
            aiAvailable: true,
            referenceFrame: frame,
          ),
        ).kind,
        AssistantRouteKind.ruleHandled,
      );
    });
  });
}
