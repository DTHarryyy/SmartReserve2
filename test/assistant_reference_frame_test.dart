import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_reference_frame.dart';

void main() {
  late AssistantReferenceFrame frame;

  setUp(() => frame = AssistantReferenceFrame());

  group('ordinals', () {
    test('resolve against the list in display order', () {
      frame.noteReservations(['r1', 'r2', 'r3']);

      expect(frame.resolveReservation(ordinal: 1).id, 'r1');
      expect(frame.resolveReservation(ordinal: 2).id, 'r2');
      expect(frame.resolveReservation(ordinal: 3).id, 'r3');
    });

    test('out of range asks rather than clamping to the nearest row', () {
      frame.noteReservations(['r1', 'r2']);

      final beyond = frame.resolveReservation(ordinal: 5);
      expect(beyond.outcome, ReferenceOutcome.outOfRange);
      expect(beyond.id, isNull);
      expect(beyond.candidateCount, 2);

      expect(
        frame.resolveReservation(ordinal: 0).outcome,
        ReferenceOutcome.outOfRange,
      );
    });

    test('an ordinal against an empty frame is out of range, not silence', () {
      // The user clearly pointed at something; saying "nothing to refer to"
      // would be less useful than saying the list does not go that far.
      expect(
        frame.resolveReservation(ordinal: 2).outcome,
        ReferenceOutcome.outOfRange,
      );
    });
  });

  group('implicit reference', () {
    test('an empty frame resolves to nothing', () {
      expect(frame.resolveReservation().outcome, ReferenceOutcome.noCandidates);
    });

    test('a single row needs no ordinal', () {
      frame.noteReservations(['only']);
      final resolved = frame.resolveReservation();
      expect(resolved.isResolved, isTrue);
      expect(resolved.id, 'only');
    });

    test('several rows with no ordinal is ambiguous, never a guess', () {
      frame.noteReservations(['r1', 'r2', 'r3']);
      final resolved = frame.resolveReservation();
      expect(resolved.outcome, ReferenceOutcome.ambiguous);
      expect(resolved.id, isNull);
      expect(resolved.candidateCount, 3);
    });

    test('focus wins over ambiguity', () {
      frame.noteReservations(['r1', 'r2', 'r3']);
      frame.noteReservationFocus('r2');
      expect(frame.resolveReservation().id, 'r2');
    });
  });

  group('availability filtering', () {
    test('resolution is restricted to ids valid for the action', () {
      frame.noteReservations(['past', 'future']);

      // "Cancel this one" must not land on a reservation that cannot be
      // cancelled just because it was the last thing shown.
      final resolved = frame.resolveReservation(available: ['future']);
      expect(resolved.id, 'future');
    });

    test('a focus outside the allowed set does not resolve', () {
      frame.noteReservations(['a', 'b']);
      frame.noteReservationFocus('a');

      final resolved = frame.resolveReservation(available: ['b']);
      expect(resolved.id, 'b', reason: 'falls through to the only valid row');
    });

    test('ordinals index the filtered list, not the displayed one', () {
      frame.noteReservations(['a', 'b', 'c']);
      expect(frame.resolveReservation(ordinal: 2, available: ['b', 'c']).id, 'c');
    });
  });

  group('facilities', () {
    test('behave the same way as reservations', () {
      frame.noteFacilities(['f1', 'f2']);
      expect(frame.resolveFacility(ordinal: 2).id, 'f2');
      expect(frame.resolveFacility().outcome, ReferenceOutcome.ambiguous);

      frame.noteFacilityFocus('f1');
      expect(frame.resolveFacility().id, 'f1');
    });

    test('a single facility becomes the focus automatically', () {
      frame.noteFacilities(['only']);
      expect(frame.focusFacilityId, 'only');
    });
  });

  group('context payload', () {
    test('carries ids only, never labels or records', () {
      frame.noteReservations(['r1', 'r2']);
      frame.noteFacilityFocus('f9');

      final payload = frame.toContextPayload();
      expect(payload['recent_reservation_ids'], ['r1', 'r2']);
      expect(payload['focus_facility_id'], 'f9');
      expect(payload.keys, isNot(contains('titles')));
    });

    test('is empty when nothing has been shown', () {
      expect(frame.toContextPayload(), isEmpty);
      expect(frame.isEmpty, isTrue);
    });

    test('is capped so a long history cannot inflate the prompt', () {
      frame.noteReservations([for (var i = 0; i < 40; i++) 'r$i']);
      expect(
        (frame.toContextPayload()['recent_reservation_ids'] as List).length,
        10,
      );
    });
  });

  test('clear forgets everything', () {
    frame.noteReservations(['r1']);
    frame.noteFacilities(['f1']);
    frame.clear();
    expect(frame.isEmpty, isTrue);
  });
}
