import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/reservation.dart';

ReservationOccurrence _occurrence({
  required DateTime startsAt,
  BookingStage stage = BookingStage.booked,
  int? checkInLateMinutes,
}) => ReservationOccurrence(
  id: 'occurrence-1',
  startsAt: startsAt,
  endsAt: startsAt.add(const Duration(hours: 2)),
  bookingState: 'booked',
  stage: stage,
  checkInLateMinutes: checkInLateMinutes,
);

void main() {
  final start = DateTime.utc(2026, 9, 25, 10);

  group('canCheckInAt', () {
    test('is closed more than 30 minutes before start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.canCheckInAt(start.subtract(const Duration(minutes: 31))),
        isFalse,
      );
    });

    test('opens exactly 30 minutes before start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.canCheckInAt(start.subtract(const Duration(minutes: 30))),
        isTrue,
      );
    });

    test('stays open at start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(occurrence.canCheckInAt(start), isTrue);
    });

    test('stays open exactly 30 minutes after start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.canCheckInAt(start.add(const Duration(minutes: 30))),
        isTrue,
      );
    });

    test('closes more than 30 minutes after start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.canCheckInAt(start.add(const Duration(minutes: 31))),
        isFalse,
      );
    });
  });

  group('lateMinutesAt', () {
    test('is zero before start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.lateMinutesAt(start.subtract(const Duration(minutes: 5))),
        0,
      );
    });

    test('is zero exactly at start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(occurrence.lateMinutesAt(start), 0);
    });

    test('rounds any overrun up to a full minute', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.lateMinutesAt(start.add(const Duration(seconds: 1))),
        1,
      );
    });

    test('counts whole minutes past start', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.lateMinutesAt(start.add(const Duration(minutes: 20))),
        20,
      );
    });
  });

  group('canMarkNoShowAt', () {
    test('is false while check-in is still open', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.canMarkNoShowAt(start.add(const Duration(minutes: 30))),
        isFalse,
      );
    });

    test('is true once check-in has closed', () {
      final occurrence = _occurrence(startsAt: start);
      expect(
        occurrence.canMarkNoShowAt(start.add(const Duration(minutes: 31))),
        isTrue,
      );
    });
  });

  group('checkedInLate', () {
    test('is false when no late minutes were recorded', () {
      final occurrence = _occurrence(startsAt: start);
      expect(occurrence.checkedInLate, isFalse);
    });

    test('is false when checked in exactly on time', () {
      final occurrence = _occurrence(startsAt: start, checkInLateMinutes: 0);
      expect(occurrence.checkedInLate, isFalse);
    });

    test('is true when checked in late', () {
      final occurrence = _occurrence(startsAt: start, checkInLateMinutes: 5);
      expect(occurrence.checkedInLate, isTrue);
    });
  });
}
