import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/assistant/assistant_availability.dart';

DateTime _nextWeekday(DateTime from, int targetWeekday) {
  var d = DateTime(from.year, from.month, from.day);
  while (d.weekday != targetWeekday) {
    d = d.add(const Duration(days: 1));
  }
  return d;
}

void main() {
  final state = AppState();
  final lab = state.facilityNamed('Computer Laboratory 1')!; // 07:00–19:00, Mon–Fri, cap 40
  final auditorium = state.facilityNamed('University Auditorium')!; // 07:00–21:00, Mon–Sun

  // A Monday far enough in the future to stay within every facility's
  // 30-day advance window relative to the fixed `now` used below.
  final anchorMonday = _nextWeekday(DateTime(2026, 8, 10), DateTime.monday);
  final now = DateTime(anchorMonday.year, anchorMonday.month, anchorMonday.day, 6, 0);

  group('freeSlotsForDay', () {
    test('no busy windows -> the full grid within open hours', () {
      final slots = freeSlotsForDay(
        facility: lab,
        day: anchorMonday,
        busy: const [],
        durationHours: 2,
      );
      expect(slots, isNotEmpty);
      expect(slots.first.startHour, lab.openHour.toDouble());
      for (final s in slots) {
        expect(s.startHour >= lab.openHour, isTrue);
        expect(s.endHour <= lab.closeHour, isTrue);
      }
    });

    test('a busy window is inflated by 2x the buffer on both sides', () {
      final slots = freeSlotsForDay(
        facility: lab, // bookingBufferMinutes defaults to 15
        day: anchorMonday,
        busy: const [BusyWindow(9, 11)],
        durationHours: 1,
        limit: 20,
      );
      // Raw 09:00-11:00 would leave 08:00-09:00 free with no buffer, but the
      // 2x15=30min buffer on each side (08:30-11:30) rules it out.
      expect(slots.any((s) => s.startHour == 8.0), isFalse);
      // Everything inside the buffered window is excluded...
      expect(slots.any((s) => s.startHour == 11.0), isFalse);
      // ...and the boundary touch at exactly 11:30 is free again (half-open,
      // matching the server's `[)` range semantics).
      expect(slots.any((s) => s.startHour == 11.5), isTrue);
    });

    test('closed weekday returns nothing', () {
      final saturday = _nextWeekday(anchorMonday, DateTime.saturday);
      final slots = freeSlotsForDay(
        facility: lab, // Mon-Fri only
        day: saturday,
        busy: const [],
        durationHours: 1,
      );
      expect(slots, isEmpty);
    });

    test('today at 14:20 offers nothing before 14:30', () {
      final today = DateTime(anchorMonday.year, anchorMonday.month, anchorMonday.day);
      final nowMidAfternoon = DateTime(today.year, today.month, today.day, 14, 20);
      final slots = freeSlotsForDay(
        facility: lab,
        day: today,
        busy: const [],
        durationHours: 1,
        nowWall: nowMidAfternoon,
      );
      expect(slots, isNotEmpty);
      expect(slots.first.startHour, 14.5);
      expect(slots.any((s) => s.startHour < 14.5), isFalse);
    });
  });

  group('checkSlot', () {
    test('a clean slot has no issues', () {
      final verdict = checkSlot(
        facility: lab,
        day: anchorMonday,
        startHour: 9,
        endHour: 11,
        heads: 20,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.ok, isTrue);
    });

    test('too long flags tooLong', () {
      final verdict = checkSlot(
        facility: lab, // maxDurationMinutes defaults to 240 (4h)
        day: anchorMonday,
        startHour: 9,
        endHour: 14, // 5h
        heads: 20,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.tooLong));
    });

    test('beyond the advance window flags beyondAdvance', () {
      final farFuture = anchorMonday.add(const Duration(days: 90));
      final verdict = checkSlot(
        facility: lab, // advanceBookingDays defaults to 30
        day: farFuture,
        startHour: 9,
        endHour: 11,
        heads: 20,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.beyondAdvance));
    });

    test('over capacity flags overCapacity', () {
      final verdict = checkSlot(
        facility: lab, // capacity 40
        day: anchorMonday,
        startHour: 9,
        endHour: 11,
        heads: 999,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.overCapacity));
    });

    test('a day before today flags inPast', () {
      final yesterday = now.subtract(const Duration(days: 1));
      final verdict = checkSlot(
        facility: lab,
        day: yesterday,
        startHour: 9,
        endHour: 11,
        heads: 20,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.inPast));
    });

    test('outside open hours flags outsideHours', () {
      final verdict = checkSlot(
        facility: lab, // closes at 19:00
        day: anchorMonday,
        startHour: 18,
        endHour: 20,
        heads: 20,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.outsideHours));
    });

    test('closed that weekday flags closedDay', () {
      final saturday = _nextWeekday(anchorMonday, DateTime.saturday);
      final verdict = checkSlot(
        facility: lab, // Mon-Fri only
        day: saturday,
        startHour: 9,
        endHour: 11,
        heads: 20,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.closedDay));
    });

    test('an overlapping busy window flags clash, alone', () {
      final verdict = checkSlot(
        facility: auditorium,
        day: anchorMonday,
        startHour: 10,
        endHour: 12,
        heads: 50,
        busy: const [BusyWindow(11, 13)],
        nowWall: now,
      );
      expect(verdict.issues, [SlotIssue.clash]);
    });

    test('a facility in maintenance flags facilityUnavailable', () {
      final court = state.facilityNamed('Main Court')!;
      final verdict = checkSlot(
        facility: court,
        day: anchorMonday,
        startHour: 9,
        endHour: 11,
        heads: 50,
        busy: const [],
        nowWall: now,
      );
      expect(verdict.issues, contains(SlotIssue.facilityUnavailable));
    });
  });

  group('nextOpenDayWithSpace', () {
    test('skips a fully-booked day and lands on the next open one', () {
      final tuesday = anchorMonday.add(const Duration(days: 1));
      final byDay = <String, List<BusyWindow>>{
        dayKey(anchorMonday): [
          BusyWindow(lab.openHour.toDouble(), lab.closeHour.toDouble()),
        ],
      };
      final result = nextOpenDayWithSpace(lab, anchorMonday, 2, byDay);
      expect(result, tuesday);
    });
  });
}
