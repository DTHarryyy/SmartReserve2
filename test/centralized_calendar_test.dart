import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/model/calendar_event.dart';
import 'package:smartreserve/model/reservation.dart';

SessionProfile _viewer(String role, {String id = 'owner'}) => SessionProfile(
  id: id,
  email: 'viewer@example.com',
  fullName: 'Same Display Name',
  role: role,
  campusClaim: null,
  campusId: null,
  unit: null,
  verificationStatus: 'verified',
  onboardingComplete: true,
  accountStatus: 'active',
  accountAccessType: 'legacy_unassigned',
  mustChangePassword: false,
  createdAt: DateTime.utc(2026),
);

ReservationRequest _request(
  String id,
  String requesterId, {
  String bookingState = 'booked',
}) => ReservationRequest(
  id: id,
  requesterId: requesterId,
  facilityId: 'hidden-facility',
  facility: 'Unlisted Facility',
  building: 'Private Building',
  room: 'Private Room',
  capacity: 40,
  requester: 'Same Display Name',
  role: 'User',
  org: 'Private Organization',
  purpose: 'Private purpose',
  date: '28 July 2026',
  start: '09:00',
  end: '10:00',
  heads: 20,
  submitted: 'now',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.approved,
  occurrences: [
    ReservationOccurrence(
      id: '$id-occurrence',
      startsAt: DateTime(2026, 7, 28, 9),
      endsAt: DateTime(2026, 7, 28, 10),
      bookingState: bookingState,
    ),
  ],
);

class _CalendarBackend implements SmartReserveBackend {
  final calls = <({List<String> facilityIds, DateTime from, DateTime to})>[];
  bool fail = false;

  @override
  Future<List<BackendPublicReservationSlot>> publicReservationCalendar({
    required List<String> facilityIds,
    required DateTime from,
    required DateTime to,
  }) async {
    calls.add((facilityIds: facilityIds, from: from, to: to));
    if (fail) throw StateError('Shared feed unavailable');
    return [
      for (final id in ['mine', 'other'])
        BackendPublicReservationSlot(
          facilityId: 'hidden-facility',
          facilityName: 'Unlisted Facility',
          occurrenceId: '$id-occurrence',
          startsAt: DateTime.utc(2026, 7, 28, 1),
          endsAt: DateTime.utc(2026, 7, 28, 2),
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected backend call: ${invocation.memberName}',
  );
}

void main() {
  for (final role in ['user', 'internal_admin', 'external_admin']) {
    test(
      '$role loads identical admin and user schedules from the shared feed',
      () async {
        final backend = _CalendarBackend();
        final state = AppState(useDemoData: false)
          ..sessionProfile = _viewer(role)
          ..backend = backend
          ..requests = [_request('mine', 'owner')]
          ..calendarAnchor = DateTime(2026, 7, 1)
          ..userCalendarAnchor = DateTime(2026, 7, 1);

        await state.refreshCalendar();
        await state.refreshUserCalendar();

        expect(backend.calls, hasLength(2));
        expect(backend.calls.every((call) => call.facilityIds.isEmpty), isTrue);
        expect(backend.calls[0].from, backend.calls[1].from);
        expect(backend.calls[0].to, backend.calls[1].to);
        expect(state.calendarError, isNull);
        expect(state.userCalendarError, isNull);
        expect(state.calendarEvents, hasLength(2));
        expect(state.userCalendarEvents, hasLength(2));
        expect(
          state.calendarEvents.map((event) => event.id),
          state.userCalendarEvents.map((event) => event.id),
        );
        final other = state.calendarEvents.singleWhere(
          (event) => !event.isMine,
        );
        expect(other.privacyMasked, isTrue);
        expect(other.canOpenRequest, isFalse);
        expect(other.facility, 'Unlisted Facility');
        expect(other.requester, 'Reserved');
        expect(state.calendarFacilities, contains('Unlisted Facility'));
      },
    );
  }

  test(
    'a shared feed failure is surfaced instead of using an incomplete admin list',
    () async {
      final backend = _CalendarBackend()..fail = true;
      final state = AppState(useDemoData: false)
        ..sessionProfile = _viewer('internal_admin')
        ..backend = backend
        ..requests = [_request('other', 'other-owner')];
      await state.refreshCalendar();
      expect(state.calendarError, contains('Shared feed unavailable'));
      expect(state.calendarLoading, isFalse);
      expect(state.calendarEvents, isEmpty);
      expect(backend.calls, hasLength(1));
    },
  );

  for (final role in ['user', 'internal_admin', 'external_admin']) {
    test(
      '$role keeps own details and masks other bookings with the same name',
      () {
        final state = AppState()
          ..sessionProfile = _viewer(role)
          ..requests = [
            _request('mine', 'owner'),
            _request('other', 'other-owner'),
          ]
          ..bookings = [];
        final events = state.calendarEvents;
        expect(events, hasLength(2));
        final mine = events.singleWhere((event) => event.isMine);
        expect(mine.purpose, 'Private purpose');
        expect(mine.canOpenRequest, isTrue);
        final other = events.singleWhere((event) => !event.isMine);
        expect(other.privacyMasked, isTrue);
        expect(other.requester, 'Reserved');
        expect(other.purpose, 'Reserved');
        expect(other.organization, isEmpty);
        expect(other.building, isEmpty);
        expect(other.room, isEmpty);
        expect(other.headcount, 0);
        expect(other.canOpenRequest, isFalse);
        expect(other.timeLabel, mine.timeLabel);
        expect(other.matchesQuery('Private purpose'), isFalse);
      },
    );
  }

  test(
    'shared feed includes unknown facilities and deduplicates own occurrences',
    () {
      final state = AppState()
        ..sessionProfile = _viewer('user')
        ..facilities = []
        ..requests = [_request('mine', 'owner')]
        ..bookings = []
        ..userCalendarSlots = [
          for (final id in ['mine', 'other'])
            PublicCalendarSlot(
              facilityId: 'hidden-facility',
              facilityName: 'Unlisted Facility',
              occurrenceId: '$id-occurrence',
              startsAt: DateTime(2026, 7, 28, 9),
              endsAt: DateTime(2026, 7, 28, 10),
            ),
        ];
      expect(state.userCalendarEvents, hasLength(2));
      expect(
        state.userCalendarEvents.where((event) => event.isMine),
        hasLength(1),
      );
      expect(
        state.userCalendarEvents.where((event) => event.privacyMasked),
        hasLength(1),
      );
      expect(state.userCalendarFacilities, contains('Unlisted Facility'));
      state.userCalendarFacilityFilter = 'Unlisted Facility';
      expect(state.visibleUserCalendarEvents, hasLength(2));
    },
  );

  test('cancelled and expired bookings do not occupy other users calendar', () {
    final state = AppState()
      ..sessionProfile = _viewer('external_admin', id: 'viewer')
      ..requests = [
        for (final bookingState in [
          'requested',
          'held',
          'booked',
          'changes_requested',
          'bumped',
          'cancelled',
          'expired',
        ])
          _request(bookingState, 'other', bookingState: bookingState),
      ]
      ..bookings = [];
    expect(state.calendarEvents, hasLength(5));
    expect(state.calendarEvents.every((event) => event.privacyMasked), isTrue);
  });

  test(
    'shared slot decodes facility names without private reservation fields',
    () {
      final slot = BackendPublicReservationSlot.fromJson({
        'facility_id': 'hidden-facility',
        'facility_name': 'Unlisted Facility',
        'occurrence_id': 'occurrence',
        'starts_at': '2026-07-28T01:00:00Z',
        'ends_at': '2026-07-28T02:00:00Z',
      });
      expect(slot.facilityName, 'Unlisted Facility');
      expect(slot.occurrenceId, 'occurrence');
    },
  );
}
