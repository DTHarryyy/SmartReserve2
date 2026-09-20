import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/assistant/assistant_ai_client.dart';
import 'package:smartreserve/features/assistant/assistant_controller.dart';
import 'package:smartreserve/model/facility.dart';

/// The governing requirement for this whole feature: SmartReserve must work
/// exactly as before when the cloud model is unavailable. Because the AI is an
/// escalation layer over an assistant that already worked, that is structural
/// rather than aspirational -- and these tests are what keep it that way.

/// Records what was asked, and answers however the test wants.
class _FakeAiClient implements AssistantAiClient {
  _FakeAiClient(this._reply);

  final AssistantAiReply Function(AssistantAiRequest request) _reply;
  final List<AssistantAiRequest> calls = [];

  @override
  Future<AssistantAiReply> ask(AssistantAiRequest request) async {
    calls.add(request);
    return _reply(request);
  }
}

class _ThrowingAiClient implements AssistantAiClient {
  @override
  Future<AssistantAiReply> ask(AssistantAiRequest request) async {
    throw StateError('the assistant service is down');
  }
}

void main() {
  late AppState state;

  setUp(() => state = AppState());

  AssistantController controllerWith(AssistantAiClient? client) {
    final controller = AssistantController(aiClient: client)..messages.clear();
    return controller;
  }

  String transcript(AssistantController controller) =>
      controller.messages.map((message) => message.text).join('\n');

  group('no AI client at all', () {
    test('every rule-answerable question is unaffected', () async {
      final controller = controllerWith(null);

      await controller.send('What reservations do I have?', state);
      expect(transcript(controller), isNotEmpty);

      controller.messages.clear();
      await controller.send('what are the rules for external renters', state);
      expect(transcript(controller).toLowerCase(), contains('down payment'));
    });

    test('an unclassifiable message still gets the deterministic reply', () async {
      final controller = controllerWith(null);
      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      expect(transcript(controller), contains("I didn't catch that"));
      expect(controller.aiDegraded, isFalse);
    });

    test('booking still walks its stages', () async {
      final controller = controllerWith(null);
      await controller.send('Book a room', state);
      expect(controller.stage, AssistantStage.needFacility);
    });
  });

  group('AI unavailable or failing', () {
    test('a thrown error never reaches the user or breaks the turn', () async {
      // The real client swallows its own errors, but the controller must not
      // depend on that: a chat turn is never allowed to fail because an
      // optional enhancement did.
      final controller = controllerWith(_ThrowingAiClient());

      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      expect(transcript(controller), contains("I didn't catch that"));
      expect(controller.aiDegraded, isTrue);
    });

    test('a degraded reply falls back to the deterministic answer', () async {
      final client = _FakeAiClient((_) => AssistantAiReply.unavailable);
      final controller = controllerWith(client);

      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      expect(transcript(controller), contains("I didn't catch that"));
      expect(
        transcript(controller),
        isNot(contains('₱')),
        reason: 'a failed model turn must not produce amounts',
      );
    });

    test('the kill switch is not reported as a degradation', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(degraded: true, failureCode: 'disabled'),
      );
      final controller = controllerWith(client);

      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      expect(transcript(controller), contains("I didn't catch that"));
      expect(
        controller.aiDegraded,
        isFalse,
        reason: 'deliberately off is not the same as broken',
      );
    });

    test('a genuine outage is flagged once for the UI', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(
          degraded: true,
          failureCode: 'provider_unavailable',
        ),
      );
      final controller = controllerWith(client);

      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);
      expect(controller.aiDegraded, isTrue);
    });
  });

  group('AI answering', () {
    test('a model answer is rendered and marked as assisted', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(
          text: 'Wala ka pang booking ngayon.',
          toolsUsed: ['get_upcoming_reservations'],
        ),
      );
      final controller = controllerWith(client);

      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      final assisted = controller.messages.where((m) => m.assisted).toList();
      expect(assisted, hasLength(1));
      expect(assisted.single.text, 'Wala ka pang booking ngayon.');
      expect(assisted.single.kind, AssistantMessageKind.aiText);
      expect(controller.aiDegraded, isFalse);
    });

    test('an assisted answer still leaves the user a next step', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(text: 'Here is what I found.'),
      );
      final controller = controllerWith(client);

      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);
      expect(
        controller.messages.any(
          (m) => m.kind == AssistantMessageKind.chips && m.chips.isNotEmpty,
        ),
        isTrue,
      );
    });
  });

  group('an unresolved facility request (the pickleball case)', () {
    // "iwant to book a reservatio for a coorut that we can play pickle ball"
    // used to instantly show every bookable facility captioned "A few rooms
    // fit", as though something had actually matched. It had not.
    const pickleballMessage =
        'iwant to book a reservatio for a coorut that we can play pickle ball';

    test(
        'with the model unavailable, the rules name the gap instead of '
        'claiming a match', () async {
      final controller = controllerWith(null);

      await controller.send(pickleballMessage, state);

      final text = transcript(controller);
      expect(text.toLowerCase(), contains('pickleball'));
      expect(text, isNot(contains('A few rooms fit')));
    });

    test('with the model available, the request escalates and its answer '
        'is used', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(
          text: "We don't have a pickleball court, but Reading Hall B is "
              'the closest thing free right now.',
        ),
      );
      final controller = controllerWith(client);

      await controller.send(pickleballMessage, state);

      expect(
        client.calls,
        isNotEmpty,
        reason: 'an unresolvable facility request must reach the model',
      );
      final assisted = controller.messages.where((m) => m.assisted).toList();
      expect(assisted, hasLength(1));
      expect(
        transcript(controller),
        isNot(contains('A few rooms fit')),
        reason: 'the deterministic fallback must not also run',
      );
    });

    test('a bare "book a room" still costs no model call', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(text: 'should not be called'),
      );
      final controller = controllerWith(client);

      await controller.send('book a room', state);

      expect(client.calls, isEmpty);
    });

    test('"suggest a facility for pickleball" offers alternatives instead '
        'of a dead end', () async {
      // The demo fixture's only Gymnasium facility is under maintenance and
      // there is no Outdoor Area entry, so nothing here can host pickleball
      // -- add one so this test actually exercises the alternatives branch,
      // not the pre-existing capacity-less dead end.
      final gym = Facility(
        id: 'gym-fixture',
        name: 'Open Gym',
        room: 'GYM-02',
        building: 'Test Building',
        category: 'Gymnasium',
        capacity: 60,
        pinConfidence: PinConfidence.verified,
        state: FacilityState.active,
        floor: 'Ground floor',
        coords: null,
        accuracy: 5,
        description: '',
        amenities: const [],
        hours: '07:00–19:00',
        days: 'Mon–Fri',
        approvalRequired: false,
        maxDuration: '4 hours',
        advance: '30 days ahead',
        updated: '',
        bookings: 0,
      );
      state.facilities = [...state.facilities, gym];
      final controller = controllerWith(null);

      await controller.send('suggest a facility for pickleball', state);

      final text = transcript(controller);
      expect(text.toLowerCase(), contains('pickleball'));
      expect(text, isNot(contains('Nothing bookable matches that right now')));
      expect(
        controller.messages.any(
          (m) =>
              m.kind == AssistantMessageKind.facilities &&
              m.facilities.any((f) => f.id == 'gym-fixture'),
        ),
        isTrue,
      );
    });
  });

  group('discovery reaches the model, and survives without it', () {
    test('a recommendation question is asked of the model', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(text: 'The Gymplex is the closest fit.'),
      );
      final controller = controllerWith(client);

      await controller.send('can you suggest a facility for 200 people', state);

      expect(client.calls, hasLength(1));
      expect(transcript(controller), contains('Gymplex'));
    });

    test('the same question still answers with the service down', () async {
      final controller = controllerWith(_ThrowingAiClient());

      await controller.send('can you suggest a facility for 200 people', state);

      // The governing requirement, on the path that now routes through the
      // model: an outage costs phrasing, never an answer.
      expect(transcript(controller).trim(), isNotEmpty);
    });

    test('an activity we cannot host is not answered as a match', () async {
      final controller = controllerWith(null);

      await controller.send(
        'what facility do you recommend for a pickleball event',
        state,
      );

      final said = transcript(controller).toLowerCase();
      expect(said, isNot(contains('facilities match')));
      expect(said, isNot(contains('one match')));
    });
  });

  group('what is sent upward', () {
    test('a rule-answerable question never reaches the model', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(text: 'should not be called'),
      );
      final controller = controllerWith(client);

      // Records and policy questions only. Discovery -- "suggest a facility
      // for 200 people" -- deliberately left this list: rules can rank a
      // catalogue but cannot judge what an activity needs, so that class now
      // goes to the model. The test below pins the other half, that it still
      // answers when the model is gone.
      for (
        final question in [
          'What reservations do I have?',
          'how much do I still need to pay',
          'can I cancel my reservation',
          'what are the rules for external renters',
          'help',
        ]
      ) {
        controller.messages.clear();
        await controller.send(question, state);
      }

      expect(
        client.calls,
        isEmpty,
        reason: 'these are the free path; a call here is a cost regression',
      );
    });

    test('out-of-scope questions are refused without a model call', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(text: 'should not be called'),
      );
      final controller = controllerWith(client);

      await controller.send('what is my grade in math', state);

      expect(client.calls, isEmpty);
      expect(transcript(controller), contains('outside what I do'));
    });

    test('the request carries ids and history, never records', () async {
      final client = _FakeAiClient(
        (_) => const AssistantAiReply(text: 'ok'),
      );
      final controller = controllerWith(client);

      await controller.send('What reservations do I have?', state);
      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      expect(client.calls, hasLength(1));
      final payload = client.calls.single.toJson();

      // Whatever travels is ids and short text. No requester name, no email.
      final encoded = payload.toString();
      expect(encoded, isNot(contains('@')));
      expect(encoded, isNot(contains(state.userAccount.email)));
      expect(payload['message'], contains('yung ano'));
    });

    test('history sent upward is bounded', () async {
      final client = _FakeAiClient((_) => const AssistantAiReply(text: 'ok'));
      final controller = controllerWith(client);

      for (var i = 0; i < 12; i++) {
        await controller.send('help', state);
      }
      await controller.send('yung ano kasi doon sa tabi ng hagdan', state);

      final history = client.calls.single.toJson()['history'] as List;
      expect(history.length, lessThanOrEqualTo(6));
    });
  });

  group('reply parsing', () {
    test('every failure shape resolves to "use the rules"', () {
      for (
        final body in <Map<String, dynamic>>[
          {'disabled': true, 'reply': null},
          {'fallback': true, 'code': 'ungrounded_amount'},
          {'code': 'rate_limited', 'retry_after_seconds': 120},
          {'reply': ''},
          {'reply': null},
          {},
        ]
      ) {
        final reply = parseAssistantAiReply(body);
        expect(reply.hasText, isFalse, reason: body.toString());
        expect(reply.degraded, isTrue, reason: body.toString());
      }
    });

    test('a rolling summary survives the round trip', () {
      // context_summary, turn_count and the client's summary field all existed
      // with no producer anywhere between them. The model now emits one on the
      // same call that answers, so it costs no extra request.
      final reply = parseAssistantAiReply({
        'reply': 'Your balance is settled.',
        'summary': '  Discussing the Gymplex booking on Friday.  ',
      });
      expect(reply.summary, 'Discussing the Gymplex booking on Friday.');

      expect(parseAssistantAiReply({'reply': 'ok'}).summary, isNull);
      expect(
        parseAssistantAiReply({'reply': 'ok', 'summary': '   '}).summary,
        isNull,
      );
      expect(parseAssistantAiReply({'reply': 'ok', 'summary': 7}).summary, isNull);
    });

    test('the request carries the whole conversation length, not the window', () {
      // The server decides whether to ask for a summary from this, so sending
      // the replayed count would mean it is never asked for.
      final request = AssistantAiRequest(
        message: 'and the second one?',
        history: const [(role: 'user', content: 'show my reservations')],
        summary: 'Earlier: asked about the gym.',
        turnCount: 14,
      );
      final json = request.toJson();
      expect(json['turn_count'], 14);
      expect(json['summary'], 'Earlier: asked about the gym.');

      // A fresh conversation sends neither.
      final fresh = AssistantAiRequest(message: 'hello').toJson();
      expect(fresh.containsKey('turn_count'), isFalse);
      expect(fresh.containsKey('summary'), isFalse);
    });

    test('a rate limit carries its wait hint through', () {
      final reply = parseAssistantAiReply({
        'code': 'rate_limited',
        'retry_after_seconds': 120,
      });
      expect(reply.failureCode, 'rate_limited');
      expect(reply.retryAfterSeconds, 120);
    });

    test('the assisted marker survives a round trip through storage', () {
      // ai_text is the wire name; the enum is aiText. A reloaded transcript
      // has to still show which answers a model wrote.
      expect(AssistantMessageKind.aiText.wireName, 'ai_text');
      expect(
        AssistantMessageKindWire.fromWire('ai_text'),
        AssistantMessageKind.aiText,
      );
      // Every other kind keeps its own name, and an unknown one degrades to
      // plain text rather than throwing on an older client.
      expect(AssistantMessageKind.text.wireName, 'text');
      expect(
        AssistantMessageKindWire.fromWire('something_newer'),
        AssistantMessageKind.text,
      );
    });

    test('a good answer is parsed with its tools and channels', () {
      final reply = parseAssistantAiReply({
        'reply': '  You still owe ₱3500.  ',
        'tools_used': ['get_payment_balance'],
        'slot_fill': {'slot': 'heads', 'heads': 30},
        'proposal': {'kind': 'cancellation', 'reservation_id': 'abc'},
      });
      expect(reply.text, 'You still owe ₱3500.');
      expect(reply.toolsUsed, ['get_payment_balance']);
      expect(reply.slotFill!['heads'], 30);
      expect(reply.proposal!['kind'], 'cancellation');
    });

    test('facility ids ride along when the answer surfaced matches', () {
      final reply = parseAssistantAiReply({
        'reply': '5 facilities fit 20 people.',
        'tools_used': ['recommend_facilities'],
        'facility_ids': ['fac-1', 'fac-2'],
      });
      expect(reply.facilityIds, ['fac-1', 'fac-2']);
    });

    test('a missing facility_ids field is simply no facilities', () {
      final reply = parseAssistantAiReply({'reply': 'ok'});
      expect(reply.facilityIds, isEmpty);
    });
  });

  group('the cards agree with the sentence above them', () {
    /// The ids of three bookable facilities, deliberately not in catalogue
    /// order.
    List<String> reversedIds(AppState state) =>
        state.bookableFacilities.take(3).map((f) => f.id).toList().reversed
            .toList();

    test('cards are shown in the order the model ranked them', () async {
      final ranked = reversedIds(state);
      final controller = controllerWith(
        _FakeAiClient(
          (_) => AssistantAiReply(
            text: 'The first one is the closest fit.',
            facilityIds: ranked,
          ),
        ),
      );

      await controller.send('what venue do you suggest for a seminar', state);

      final shown = controller.messages
          .expand((message) => message.facilities)
          .map((facility) => facility.id)
          .toList();
      // "The first one is the closest fit" is a lie if the first card is not
      // the one the model put first.
      expect(shown, ranked);
    });

    test('one suggestion becomes the draft, so "book it" works next turn', () async {
      final only = state.bookableFacilities.first;
      final controller = controllerWith(
        _FakeAiClient(
          (_) => AssistantAiReply(
            text: '${only.name} is the only one that fits.',
            facilityIds: [only.id],
          ),
        ),
      );

      await controller.send('what venue do you suggest for a seminar', state);

      expect(controller.draft.facility?.id, only.id);
    });

    test('an id this user cannot book is dropped, not rendered', () async {
      final real = state.bookableFacilities.first;
      final controller = controllerWith(
        _FakeAiClient(
          (_) => AssistantAiReply(
            text: 'Two options.',
            facilityIds: ['not-a-real-facility', real.id],
          ),
        ),
      );

      await controller.send('what venue do you suggest for a seminar', state);

      final shown = controller.messages
          .expand((message) => message.facilities)
          .map((facility) => facility.id)
          .toList();
      expect(shown, [real.id]);
    });
  });
}
