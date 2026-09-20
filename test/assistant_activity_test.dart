import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_nlu.dart';

/// A booking request naming a sport we have no dedicated facility for used to
/// be misread twice over: the activity words got filed as the reservation's
/// purpose, and the facility step fell back to showing every bookable room as
/// though it had matched. These tests pin the parser's half of the fix.
final _now = DateTime(2026, 9, 20);

void main() {
  group('matchActivity', () {
    test('recognises an activity however it is spelled', () {
      expect(matchActivity('we can play pickle ball'), 'pickleball');
      expect(matchActivity('pickleball tournament'), 'pickleball');
      expect(matchActivity('badminton practice'), 'badminton');
    });

    test('does not fire on unrelated short words', () {
      // "ten" must not prefix-match "tennis" -- see the length guard in
      // matchActivity.
      expect(matchActivity('the ten students need a room'), isNull);
      expect(matchActivity('for a department meeting'), isNull);
      expect(matchActivity('thesis defense'), isNull);
    });
  });

  group('the facility description is not filed as a purpose', () {
    test('the reported message keeps the activity out of purpose', () {
      final p = parseMessage(
        'iwant to book a reservatio for a coorut that we can play pickle ball',
        nowWall: _now,
      );
      expect(p.activity, 'pickleball');
      expect(
        p.purpose,
        isNull,
        reason: 'this describes the room, not the reason for booking it',
      );
      expect(p.intent, AssistantIntent.book);
    });

    test('a real purpose is still captured', () {
      final p = parseMessage(
        'book the auditorium for a department meeting',
        nowWall: _now,
      );
      expect(p.purpose, 'department meeting');
      expect(p.activity, isNull);
    });

    test('a purpose naming a facility noun is not captured either', () {
      final p = parseMessage(
        'book a room for a gym session',
        nowWall: _now,
      );
      expect(p.purpose, isNull);
    });
  });
}
