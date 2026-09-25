import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/reservation.dart';

ReservationOccurrence _occurrence({
  required BookingStage stage,
  required DateTime endsAt,
}) => ReservationOccurrence(
  id: 'occurrence-1',
  startsAt: endsAt.subtract(const Duration(hours: 2)),
  endsAt: endsAt,
  bookingState: 'booked',
  stage: stage,
);

void main() {
  group('reservation occurrence completion gate', () {
    final end = DateTime.utc(2026, 9, 25, 10);

    test('checked-in occurrence cannot complete before its end time', () {
      final occurrence = _occurrence(
        stage: BookingStage.checkedIn,
        endsAt: end,
      );

      expect(
        occurrence.canCompleteAt(
          end.subtract(const Duration(milliseconds: 1)),
        ),
        isFalse,
      );
    });

    test('checked-in occurrence can complete at and after its end time', () {
      final occurrence = _occurrence(
        stage: BookingStage.checkedIn,
        endsAt: end,
      );

      expect(occurrence.canCompleteAt(end), isTrue);
      expect(
        occurrence.canCompleteAt(end.add(const Duration(minutes: 1))),
        isTrue,
      );
    });

    test('occurrence still requires check-in after its end time', () {
      final occurrence = _occurrence(
        stage: BookingStage.booked,
        endsAt: end,
      );

      expect(
        occurrence.canCompleteAt(end.add(const Duration(minutes: 1))),
        isFalse,
      );
    });
  });
}
