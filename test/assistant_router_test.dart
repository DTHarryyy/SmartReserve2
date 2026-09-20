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
///
/// Discovery questions -- "what should I book for X" -- were deliberately
/// moved out of this set: rules can rank a catalogue but cannot map an
/// arbitrary activity onto one, nor say honestly that nothing here fits. They
/// are covered by [_expectEscalates] instead, which also pins the other half
/// of that bargain: with no model available they must come back here.
void _expectFree(
  String text,
  AssistantIntent expected, {
  AssistantRouteContext context = const AssistantRouteContext(
    aiAvailable: true,
  ),
}) {
  final route = _route(text, context: context);
  expect(
    route.kind,
    AssistantRouteKind.ruleHandled,
    reason: '"$text" must be answered by rules, not the model',
  );
  expect(route.intent, expected, reason: 'intent for "$text"');
}

/// A phrase that should reach the model when one is available -- and must
/// still be rule-answerable when one is not.
void _expectEscalates(
  String text,
  EscalationReason expected, {
  AssistantRouteContext context = const AssistantRouteContext(
    aiAvailable: true,
  ),
}) {
  final route = _route(text, context: context);
  expect(
    route.kind,
    AssistantRouteKind.escalate,
    reason: '"$text" is where the model earns its place',
  );
  expect(route.reason, expected, reason: 'escalation reason for "$text"');

  // The governing invariant: the model may only ever improve a turn. Without
  // one, the same message has to route to a handler that still answers.
  final offline = _route(
    text,
    context: const AssistantRouteContext(aiAvailable: false),
  );
  expect(
    offline.kind,
    AssistantRouteKind.ruleHandled,
    reason: '"$text" must still be answerable with the model down',
  );
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
    test('the named recommendation phrasings reach the model', () {
      _expectEscalates(
        'can you suggest a facility for 200 people',
        EscalationReason.discovery,
      );
      _expectEscalates(
        'recommend a facility where i want a office type haved a aircon',
        EscalationReason.discovery,
      );
    });

    test('an activity no dictionary covers still escalates', () {
      // The case that produced "7 facilities match:" under a bare catalogue
      // dump. There is no pickleball facility, and saying so is a judgement
      // no fixed activity map can be relied on to make.
      _expectEscalates(
        'what facility do you recommend for a pickleball event',
        EscalationReason.discovery,
      );
      _expectEscalates(
        'what venues do you suggest for a thesis defense',
        EscalationReason.discovery,
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

    test('open-ended browsing reaches the model', () {
      _expectEscalates(
        'What facilities are available?',
        EscalationReason.discovery,
      );
    });

    test('availability for one named facility stays free', () {
      // The cost guard that matters most, because this is the commonest
      // question of all: with one facility and a day, the rules read the live
      // schedule and state the free windows exactly. A model call here would
      // buy nothing and be charged for on every turn.
      _expectFree(
        'Is the gym available tomorrow?',
        AssistantIntent.checkAvailability,
        // Supplied by the controller, which is the only layer that can see
        // the catalogue; the router stays a pure function.
        context: const AssistantRouteContext(
          aiAvailable: true,
          facilityResolved: true,
        ),
      );
    });

    test('availability with no facility named does reach the model', () {
      // "Which one?" plus eight unranked cards is what the rules can manage
      // here, which is the answer this whole change exists to replace.
      _expectEscalates(
        'what rooms are free on friday afternoon',
        EscalationReason.discovery,
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

  group('an unresolved facility request', () {
    test(
        'a booking whose facility could not be resolved escalates when the '
        'model is available', () {
      final route = _route(
        'book a pickleball court',
        context: const AssistantRouteContext(
          aiAvailable: true,
          facilityRequestUnresolved: true,
        ),
      );
      expect(route.kind, AssistantRouteKind.escalate);
      expect(route.reason, EscalationReason.unresolvedFacilityRequest);
    });

    test('the same request stays rule-handled with the model unavailable',
        () {
      final route = _route(
        'book a pickleball court',
        context: const AssistantRouteContext(
          aiAvailable: false,
          facilityRequestUnresolved: true,
        ),
      );
      expect(route.kind, AssistantRouteKind.ruleHandled);
      expect(route.intent, AssistantIntent.book);
    });

    test('a bare "book a room" never escalates -- nothing was unresolved',
        () {
      final route = _route(
        'book a room',
        context: const AssistantRouteContext(
          aiAvailable: true,
          facilityRequestUnresolved: false,
        ),
      );
      expect(route.kind, AssistantRouteKind.ruleHandled);
      expect(route.intent, AssistantIntent.book);
    });

    test('an in-progress booking still escalates as unparsedBookingSlot, '
        'not this new reason', () {
      final route = routeMessage(
        parseMessage('sa makalawa siguro tanghali', nowWall: _now),
        context: const AssistantRouteContext(
          inBookingFlow: true,
          aiAvailable: true,
          facilityRequestUnresolved: true,
        ),
      );
      expect(route.kind, AssistantRouteKind.escalate);
      expect(route.reason, EscalationReason.unparsedBookingSlot);
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
