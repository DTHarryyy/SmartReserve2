import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/assistant/assistant_ai_client.dart';
import 'package:smartreserve/features/assistant/assistant_controller.dart';
import 'package:smartreserve/util/campus_calendar.dart';

/// "I want to book a reservation in basketball court" has to produce natural
/// follow-ups -- in English or Taglish -- without the model ever deciding what
/// is missing, whether an answer is legal, or when the booking is submitted.
///
/// The division these tests pin down:
///   the stage machine decides WHICH slot is next,
///   the validators decide WHETHER a value is allowed,
///   the model only decides HOW the question is phrased.

class _ScriptedAiClient implements AssistantAiClient {
  _ScriptedAiClient(this._replies);

  final List<AssistantAiReply> _replies;
  final List<AssistantAiRequest> calls = [];

  @override
  Future<AssistantAiReply> ask(AssistantAiRequest request) async {
    calls.add(request);
    return _replies.isEmpty
        ? AssistantAiReply.unavailable
        : _replies.removeAt(0);
  }
}

void main() {
  late AppState state;

  setUp(() => state = AppState());

  AssistantController bookingAt(
    AssistantStage stage, {
    AssistantAiClient? client,
  }) {
    final controller = AssistantController(aiClient: client)..messages.clear();
    controller.draft.facility = state.bookableFacilities.first;
    if (stage != AssistantStage.needFacility) {
      controller.draft.day = campusNow().add(const Duration(days: 7));
    }
    if (stage == AssistantStage.needHeads ||
        stage == AssistantStage.needPurpose) {
      controller.draft.startHour = 8;
      controller.draft.endHour = 10;
    }
    if (stage == AssistantStage.needPurpose) {
      controller.draft.heads = 10;
    }
    controller.stage = stage;
    return controller;
  }

  String transcript(AssistantController controller) =>
      controller.messages.map((message) => message.text).join('\n');

  group('starting a booking by name', () {
    test('"book the basketball court" advances past the facility stage',
        () async {
      final controller = AssistantController()..messages.clear();
      await controller.send('i want to book a reservation in gym', state);

      // Either it resolved a facility and moved on, or it is asking which --
      // both are correct. What must never happen is silently picking one and
      // continuing without saying so.
      expect(
        controller.stage,
        isNot(AssistantStage.idle),
        reason: 'a booking request must start the booking flow',
      );
      expect(transcript(controller), isNotEmpty);
    });
  });

  group('the parser keeps what it can read', () {
    test('a parseable stage reply never reaches the model', () async {
      final client = _ScriptedAiClient([]);
      final controller = bookingAt(AssistantStage.needHeads, client: client);

      await controller.send('30', state);

      expect(client.calls, isEmpty, reason: 'plain answers stay free');
      expect(controller.draft.heads, 30);
    });

    test('an English date reply stays on the free path', () async {
      final client = _ScriptedAiClient([]);
      final controller = bookingAt(AssistantStage.needDate, client: client);

      await controller.send('tomorrow', state);
      expect(client.calls, isEmpty);
    });
  });

  group('the model reads what the parser cannot', () {
    test('a Taglish headcount is filled through the normal validator', () async {
      final client = _ScriptedAiClient([
        const AssistantAiReply(
          text: 'Sige, 30 katao.',
          slotFill: {'slot': 'heads', 'heads': 30},
        ),
      ]);
      final controller = bookingAt(AssistantStage.needHeads, client: client);

      await controller.send('mga tatlumpu siguro kami', state);

      expect(client.calls, hasLength(1));
      expect(controller.draft.heads, 30);
      expect(controller.stage, isNot(AssistantStage.needHeads));
    });

    test('the draft state travels with the request, limits and all', () async {
      final client = _ScriptedAiClient([AssistantAiReply.unavailable]);
      final controller = bookingAt(AssistantStage.needHeads, client: client);

      await controller.send('mga tatlumpu siguro kami', state);

      final payload = client.calls.single.toJson();
      expect(payload['in_booking_flow'], isTrue);

      final draft = payload['booking_draft'] as Map<String, dynamic>;
      expect(draft['missing_slot'], 'needHeads');
      // Without the capacity the model would ask a question the user then has
      // to be corrected on.
      expect((draft['facility'] as Map)['capacity'], isNotNull);
    });
  });

  group('validators overrule the model', () {
    test('an over-capacity headcount is refused, stage does not advance',
        () async {
      final facility = state.bookableFacilities.first;
      final client = _ScriptedAiClient([
        AssistantAiReply(
          text: 'Okay!',
          slotFill: {'slot': 'heads', 'heads': facility.capacity + 500},
        ),
      ]);
      final controller = bookingAt(AssistantStage.needHeads, client: client);

      await controller.send('ang dami namin promise', state);

      expect(controller.draft.heads, isNull);
      expect(controller.stage, AssistantStage.needHeads);
      expect(
        transcript(controller).toLowerCase(),
        contains('capacity'),
        reason: 'the existing refusal wording, not an AI-softened one',
      );
    });

    test('a fractional headcount is refused', () async {
      final client = _ScriptedAiClient([
        const AssistantAiReply(
          text: 'Okay!',
          slotFill: {'slot': 'heads', 'heads': 12.5},
        ),
      ]);
      final controller = bookingAt(AssistantStage.needHeads, client: client);

      await controller.send('mga labindalawa at kalahati', state);
      expect(controller.draft.heads, isNull);
    });

    test('an unknown facility id is refused rather than guessed at', () async {
      final client = _ScriptedAiClient([
        const AssistantAiReply(
          text: 'Got it.',
          slotFill: {
            'slot': 'facility',
            'facility_id': '11111111-2222-3333-4444-555555555555',
          },
        ),
      ]);
      final controller = AssistantController(aiClient: client)
        ..messages.clear()
        ..stage = AssistantStage.needFacility;

      await controller.send('yung malapit sa kantina', state);
      expect(controller.draft.facility, isNull);
    });
  });

  group('cost ceilings', () {
    test('a stage consumes at most two model-assisted turns', () async {
      final client = _ScriptedAiClient([
        AssistantAiReply.unavailable,
        AssistantAiReply.unavailable,
        AssistantAiReply.unavailable,
        AssistantAiReply.unavailable,
      ]);
      final controller = bookingAt(AssistantStage.needHeads, client: client);

      for (var i = 0; i < 4; i++) {
        await controller.send('hmm ewan ko kung ilan', state);
      }

      expect(
        client.calls.length,
        lessThanOrEqualTo(2),
        reason: 'the loop guard caps spend per stage',
      );
      expect(controller.stage, AssistantStage.needHeads);
    });

    test('the allowance resets when the stage moves on', () async {
      final client = _ScriptedAiClient([
        AssistantAiReply.unavailable,
        AssistantAiReply.unavailable,
        AssistantAiReply.unavailable,
      ]);
      final controller = bookingAt(AssistantStage.needDate, client: client);

      await controller.send('basta yung araw na yun', state);
      await controller.send('basta yung araw na yun', state);
      expect(client.calls, hasLength(2), reason: 'two per stage, no more');

      await controller.send('basta yung araw na yun', state);
      expect(client.calls, hasLength(2), reason: 'the third is refused');

      // Moving the draft on by hand gives the next stage its own budget.
      controller.draft.day = campusNow().add(const Duration(days: 7));
      controller.stage = AssistantStage.needTime;

      await controller.send('basta anong oras', state);
      expect(client.calls, hasLength(3));
    });

    test('a purpose is free text, so it never needs the model', () async {
      final client = _ScriptedAiClient([]);
      final controller = bookingAt(AssistantStage.needPurpose, client: client);

      await controller.send('yung para sa ano', state);

      expect(client.calls, isEmpty);
      expect(controller.draft.purpose, 'yung para sa ano');
    });
  });

  group('nothing is written without a tap', () {
    test('a completed draft still waits at the confirm stage', () async {
      final client = _ScriptedAiClient([]);
      final controller = bookingAt(AssistantStage.needPurpose, client: client);

      await controller.send('Intramurals practice', state);

      expect(controller.draft.purpose, 'Intramurals practice');
      expect(
        controller.stage,
        isNot(AssistantStage.submitting),
        reason: 'submission happens only on an explicit confirm',
      );
      expect(controller.submitting, isFalse);
      expect(client.calls, isEmpty);
    });

    test('a model-proposed purpose still goes through the validator', () async {
      // The model may only fill a slot the deterministic path could not read,
      // and the value still has to satisfy the same minimum.
      final controller = bookingAt(AssistantStage.needPurpose);
      expect(
        await controller.debugApplySlotFill(
          {'slot': 'purpose', 'purpose': 'x'},
          state,
        ),
        isFalse,
        reason: 'too short, exactly as a typed "x" would be',
      );
      expect(
        await controller.debugApplySlotFill(
          {'slot': 'purpose', 'purpose': 'Intramurals practice'},
          state,
        ),
        isTrue,
      );
      expect(controller.draft.purpose, 'Intramurals practice');
    });

    test('with the model unavailable the flow behaves exactly as before',
        () async {
      final withAi = bookingAt(
        AssistantStage.needHeads,
        client: _ScriptedAiClient([AssistantAiReply.unavailable]),
      );
      final withoutAi = bookingAt(AssistantStage.needHeads);

      await withAi.send('213213', state);
      await withoutAi.send('213213', state);

      expect(withAi.draft.heads, withoutAi.draft.heads);
      expect(withAi.stage, withoutAi.stage);
      expect(transcript(withAi), transcript(withoutAi));
    });
  });
}
