import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/student/booking_sheet.dart';

/// The assistant used to collect a facility, a day, a time, a headcount and a
/// purpose, and then hand the booking sheet nothing but the facility -- so the
/// review step asked for all of it over again.
///
/// [resolveBookingPrefill] is the substance of the fix: deciding what a
/// carried-over value is actually allowed to select. The rest of the prefill
/// is assignment. What these tests guard hardest is the refusal path -- a
/// prefill is a proposal, never an override, because silently sliding someone
/// to a neighbouring slot books a time they never agreed to.

final _monday = DateTime(2026, 9, 21);
final _tuesday = DateTime(2026, 9, 22);
final _wednesday = DateTime(2026, 9, 23);

const _fullDay = [
  '08:00', '08:30', '09:00', '09:30', '10:00', '10:30',
  '11:00', '11:30', '12:00', '12:30', '13:00', '13:30',
  '14:00', '14:30', '15:00', '15:30', '16:00', '16:30', '17:00',
];

/// Today is half gone, so the first day's list starts late -- the shape that
/// makes "which slots are legal" depend on which date won.
const _afternoonOnly = ['14:00', '14:30', '15:00', '15:30', '16:00'];

BookingPrefillResolution _resolve(
  BookingPrefill prefill, {
  List<DateTime>? dates,
  List<String> Function(int)? slotsFor,
  int fallbackDateIndex = 0,
}) => resolveBookingPrefill(
  prefill: prefill,
  dates: dates ?? [_monday, _tuesday, _wednesday],
  slotsFor: slotsFor ?? (index) => index == 0 ? _afternoonOnly : _fullDay,
  fallbackDateIndex: fallbackDateIndex,
);

void main() {
  group('bookingClockLabel', () {
    test('writes hours in the slot lists own spelling', () {
      expect(bookingClockLabel(13), '13:00');
      expect(bookingClockLabel(13.5), '13:30');
      expect(bookingClockLabel(8), '08:00');
      expect(bookingClockLabel(null), isNull);
    });
  });

  group('a value the facility can honour is kept', () {
    test('the day, start and end all carry over', () {
      final resolution = _resolve(
        BookingPrefill(
          day: _tuesday,
          startHour: 10,
          endHour: 12,
          heads: 37,
          purpose: 'Departmental planning',
        ),
      );

      expect(resolution.dateIndex, 1);
      expect(resolution.start, '10:00');
      expect(resolution.end, '12:00');
      expect(resolution.rejected, isEmpty);
    });

    test('a half-hour window is kept intact', () {
      final resolution = _resolve(
        BookingPrefill(day: _wednesday, startHour: 9.5, endHour: 11.5),
      );

      expect(resolution.start, '09:30');
      expect(resolution.end, '11:30');
      expect(resolution.rejected, isEmpty);
    });

    test('an empty prefill selects nothing and rejects nothing', () {
      final resolution = _resolve(const BookingPrefill());

      expect(resolution.dateIndex, isNull);
      expect(resolution.start, isNull);
      expect(resolution.end, isNull);
      expect(resolution.rejected, isEmpty);
    });
  });

  group('a value the facility cannot honour is refused, not forced', () {
    test('a day the facility is shut on is reported', () {
      final resolution = _resolve(
        BookingPrefill(day: DateTime(2026, 12, 25), startHour: 10, endHour: 12),
      );

      // Null means "keep your own default", which the sheet then does -- and
      // 'date' is what makes it say so rather than quietly booking another day.
      expect(resolution.dateIndex, isNull);
      expect(resolution.rejected, contains('date'));
    });

    test('an hour outside the days slots is reported', () {
      final resolution = _resolve(
        // 09:00 is legal on Tuesday but not on Monday, whose list starts at 14.
        BookingPrefill(day: _monday, startHour: 9, endHour: 11),
      );

      expect(resolution.dateIndex, 0);
      expect(resolution.start, isNull);
      expect(resolution.rejected, contains('time'));
    });

    test('an end that is not after the start is refused', () {
      final resolution = _resolve(
        BookingPrefill(day: _tuesday, startHour: 12, endHour: 10),
      );

      expect(resolution.start, '12:00');
      expect(resolution.end, isNull);
      expect(resolution.rejected, contains('time'));
    });

    test('a start with no end keeps the start and flags the gap', () {
      final resolution = _resolve(
        BookingPrefill(day: _tuesday, startHour: 10),
      );

      expect(resolution.start, '10:00');
      expect(resolution.end, isNull);
      expect(resolution.rejected, contains('time'));
    });
  });

  group('the hours are read against the day that won', () {
    test('a prefilled date changes which slots are legal', () {
      // The same 09:00 is refused on day 0 and kept on day 1. Reading the slot
      // list before the date is settled is exactly the bug this pins.
      expect(
        _resolve(BookingPrefill(day: _monday, startHour: 9, endHour: 11)).start,
        isNull,
      );
      expect(
        _resolve(BookingPrefill(day: _tuesday, startHour: 9, endHour: 11)).start,
        '09:00',
      );
    });

    test('with no date given the callers current day is used', () {
      final resolution = _resolve(
        const BookingPrefill(startHour: 9, endHour: 11),
        fallbackDateIndex: 1,
      );

      expect(resolution.dateIndex, isNull, reason: 'no date was proposed');
      expect(resolution.start, '09:00', reason: 'day 1 allows the morning');
    });
  });
}
