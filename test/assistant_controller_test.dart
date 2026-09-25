import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/data/campus_data.dart';
import 'package:smartreserve/features/assistant/assistant_controller.dart';
import 'package:smartreserve/features/assistant/assistant_nlu.dart';
import 'package:smartreserve/model/amenity_request.dart';

void main() {
  late AppState state;
  late AssistantController controller;

  setUp(() {
    state = AppState();
    controller = AssistantController();
    controller.messages.clear();
    controller.draft.facility = state.bookableFacilities.first;
    controller.draft.day = DateTime(2026, 8, 31);
    controller.draft.startHour = 8;
    controller.draft.endHour = 10;
    controller.stage = AssistantStage.needHeads;
  });

  test(
    'six-digit attendee input is rejected once without repeating prompt',
    () async {
      await controller.send('213213', state);

      expect(controller.draft.heads, isNull);
      expect(controller.stage, AssistantStage.needHeads);
      expect(
        controller.messages
            .where((message) => message.text.contains('exceeds'))
            .length,
        1,
      );
      expect(
        controller.messages.where(
          (message) => message.text == 'About how many people?',
        ),
        isEmpty,
      );
    },
  );

  test('selected facility capacity is enforced for attendee input', () async {
    final overCapacity = controller.draft.facility!.capacity + 1;

    await controller.send('$overCapacity', state);

    expect(controller.draft.heads, isNull);
    expect(controller.stage, AssistantStage.needHeads);
    expect(
      controller.messages.where((message) => message.text.contains('capacity')),
      isNotEmpty,
    );
  });

  test(
    'negative and decimal attendee inputs do not advance the draft',
    () async {
      await controller.send('-5', state);
      expect(controller.draft.heads, isNull);
      expect(controller.stage, AssistantStage.needHeads);
      expect(controller.messages.last.text, contains('cannot be negative'));

      await controller.send('12.5', state);
      expect(controller.draft.heads, isNull);
      expect(controller.stage, AssistantStage.needHeads);
      expect(controller.messages.last.text, contains('whole number'));
    },
  );

  test('amenity parsing and normalization use the shared catalog', () {
    final parsed = parseMessage(
      'Book with coffee and wifi projector cctv',
      nowWall: DateTime(2026, 8, 30),
    );

    expect(knownAmenityLabels, standardAmenityLabels);
    expect(
      parsed.amenities,
      containsAll(['Wi-Fi', 'Projector', 'Security Cameras']),
    );
    expect(parsed.unknownAmenityWords, contains('coffee'));

    final facility = state.bookableFacilities.first;
    final normalized = normalizeRequestedAmenityLabels(facility, [
      ...parsed.amenities,
      'Generator',
      'Custom tag',
    ]);

    expect(normalized, ['Security Cameras', 'Generator']);
  });

  test('booking sheet success is acknowledged in the chatbot', () {
    controller.draft.heads = 20;
    controller.draft.purpose = 'Department planning';

    controller.noteBookingSubmitted(
      facility: 'Conference Room',
      date: 'Sep 30, 2026',
      start: '09:00',
      end: '11:00',
      adminLane: 'internal',
      reservationId: 'reservation-123',
    );

    expect(
      controller.messages.any(
        (message) =>
            message.text.contains(
              'Thank you for reserving with SmartReserve',
            ) &&
            message.text.contains('submitted successfully'),
      ),
      isTrue,
    );
    expect(controller.messages.last.kind, AssistantMessageKind.activity);
    expect(controller.messages.last.reservationId, 'reservation-123');
    expect(controller.stage, AssistantStage.idle);
    expect(controller.draft.facility, isNull);
  });
}
