import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_availability.dart';
import 'package:smartreserve/model/facility.dart';

Facility _facility({
  String days = 'Mon–Sun',
  String hours = '08:00–12:00',
  int maxDurationMinutes = 240,
}) =>
    Facility(
      id: 'facility-1',
      name: 'Test Room',
      room: 'R-1',
      building: 'Main',
      category: 'Conference Room',
      capacity: 20,
      pinConfidence: PinConfidence.verified,
      state: FacilityState.active,
      floor: 'Ground floor',
      coords: null,
      accuracy: null,
      description: '',
      amenities: const [],
      hours: hours,
      days: days,
      approvalRequired: true,
      maxDuration: '4 hours',
      advance: '30 days ahead',
      updated: '',
      bookings: 0,
      maxDurationMinutes: maxDurationMinutes,
      bookingBufferMinutes: 0,
    );

void main() {
  test('available booking days exclude closed and fully occupied days', () {
    final facility = _facility(days: 'Mon–Fri');
    final monday = DateTime(2026, 8, 31);
    final days = availableBookingDaysForFacility(
      facility: facility,
      fromWall: monday,
      toWall: monday.add(const Duration(days: 6)),
      busy: {
        '${facility.id}|${dayKey(monday)}': const [BusyWindow(8, 12)],
      },
      durationHours: 2,
      nowWall: DateTime(2026, 8, 31, 7),
    );

    expect(days.map((item) => dayKey(item.day)), [
      '2026-09-01',
      '2026-09-02',
      '2026-09-03',
      '2026-09-04',
    ]);
  });

  test('free slot generation respects the facility maximum duration', () {
    final slots = freeSlotsForDay(
      facility: _facility(maxDurationMinutes: 60),
      day: DateTime(2026, 8, 31),
      busy: const [],
      durationHours: 2,
      nowWall: DateTime(2026, 8, 31, 7),
    );

    expect(slots, isEmpty);
  });
}
