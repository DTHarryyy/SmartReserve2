import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_availability.dart';
import 'package:smartreserve/model/facility.dart';

Facility _facility({
  String days = 'Mon–Sun',
  String hours = '08:00–12:00',
  int maxDurationMinutes = 240,
  int capacity = 20,
  int advanceBookingDays = 30,
  int bookingBufferMinutes = 0,
  FacilityState state = FacilityState.active,
}) => Facility(
  id: 'facility-1',
  name: 'Test Room',
  room: 'R-1',
  building: 'Main',
  category: 'Conference Room',
  capacity: capacity,
  pinConfidence: PinConfidence.verified,
  state: state,
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
  advanceBookingDays: advanceBookingDays,
  bookingBufferMinutes: bookingBufferMinutes,
);

void main() {
  group('checkSlot', _checkSlotTests);

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

// ---------------------------------------------------------------------------
// checkSlot
//
// The authoritative gate. A typed booking, a tapped one and a model-proposed
// one all pass through here, so every issue it can raise is a way the app
// stops someone booking something it cannot honour. It had no direct tests:
// the nine issues were only ever exercised incidentally, through controller
// and proposal tests that assert on wording rather than on the verdict.
//
// It accumulates rather than short-circuits, which is what lets the assistant
// explain everything wrong with a request in one reply instead of sending the
// user round the loop once per problem. That property is asserted too.
// ---------------------------------------------------------------------------

void _expectIssue(SlotVerdict verdict, SlotIssue issue) {
  expect(verdict.ok, isFalse);
  expect(verdict.issues, contains(issue));
}

void _checkSlotTests() {
  final monday = DateTime(2026, 9, 21);
  final now = DateTime(2026, 9, 21, 7, 0);

  SlotVerdict verdict({
    Facility? facility,
    DateTime? day,
    double startHour = 9,
    double endHour = 11,
    int heads = 10,
    List<BusyWindow> busy = const [],
    DateTime? nowWall,
  }) => checkSlot(
    facility: facility ?? _facility(),
    day: day ?? monday,
    startHour: startHour,
    endHour: endHour,
    heads: heads,
    busy: busy,
    nowWall: nowWall ?? now,
  );

  test('a legal slot raises nothing at all', () {
    expect(verdict().ok, isTrue);
  });

  test('an end at or before the start is a zero duration', () {
    _expectIssue(verdict(startHour: 10, endHour: 10), SlotIssue.zeroDuration);
    _expectIssue(verdict(startHour: 11, endHour: 10), SlotIssue.zeroDuration);
  });

  test('a facility under maintenance cannot be booked', () {
    _expectIssue(
      verdict(facility: _facility(state: FacilityState.maintenance)),
      SlotIssue.facilityUnavailable,
    );
  });

  test('a day the facility does not open is refused', () {
    // 2026-09-26 is a Saturday.
    _expectIssue(
      verdict(facility: _facility(days: 'Mon–Fri'), day: DateTime(2026, 9, 26)),
      SlotIssue.closedDay,
    );
  });

  test('either end outside opening hours is refused', () {
    _expectIssue(verdict(startHour: 7, endHour: 9), SlotIssue.outsideHours);
    _expectIssue(verdict(startHour: 11, endHour: 13), SlotIssue.outsideHours);
  });

  test('a booking longer than the facility allows is refused', () {
    _expectIssue(
      verdict(
        facility: _facility(maxDurationMinutes: 60),
        startHour: 8,
        endHour: 11,
      ),
      SlotIssue.tooLong,
    );
  });

  test('more heads than the room holds is refused', () {
    _expectIssue(
      verdict(facility: _facility(capacity: 8), heads: 9),
      SlotIssue.overCapacity,
    );
  });

  test('a day already gone is in the past', () {
    _expectIssue(verdict(day: DateTime(2026, 9, 20)), SlotIssue.inPast);
  });

  test('an hour already gone today is in the past, but a later one is not', () {
    final midday = DateTime(2026, 9, 21, 10, 30);
    _expectIssue(
      verdict(startHour: 9, endHour: 10, nowWall: midday),
      SlotIssue.inPast,
    );
    expect(verdict(startHour: 11, endHour: 12, nowWall: midday).ok, isTrue);
  });

  test('a day past the advance window is refused', () {
    _expectIssue(
      verdict(
        facility: _facility(advanceBookingDays: 7),
        day: DateTime(2026, 10, 30),
      ),
      SlotIssue.beyondAdvance,
    );
  });

  test('an overlapping booking clashes', () {
    _expectIssue(
      verdict(busy: const [BusyWindow(10, 12)]),
      SlotIssue.clash,
    );
    expect(verdict(busy: const [BusyWindow(11, 12)]).ok, isTrue);
  });

  test('the buffer keeps a clash away from an adjacent booking', () {
    // A 15-minute buffer inflates each busy window by half an hour on each
    // edge, so a booking that merely touches an existing one still clashes.
    _expectIssue(
      verdict(
        facility: _facility(bookingBufferMinutes: 15),
        busy: const [BusyWindow(11, 12)],
      ),
      SlotIssue.clash,
    );
  });

  test('every problem is reported at once, not one per attempt', () {
    // Short-circuiting would send the user round the loop once per mistake.
    final all = checkSlot(
      facility: _facility(
        days: 'Mon–Fri',
        capacity: 5,
        maxDurationMinutes: 60,
        state: FacilityState.maintenance,
      ),
      day: DateTime(2026, 9, 26),
      startHour: 6,
      endHour: 14,
      heads: 40,
      busy: const [],
      nowWall: now,
    );
    expect(
      all.issues,
      containsAll(<SlotIssue>[
        SlotIssue.facilityUnavailable,
        SlotIssue.closedDay,
        SlotIssue.outsideHours,
        SlotIssue.tooLong,
        SlotIssue.overCapacity,
      ]),
    );
  });
}
