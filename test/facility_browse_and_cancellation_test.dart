import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/model/facility.dart';
import 'package:smartreserve/model/reservation.dart';

ReservationRequest _requestWithOccurrences(
  List<ReservationOccurrence> occurrences,
) => ReservationRequest(
  id: 'cancel-test',
  facility: 'Test Facility',
  building: 'Test Building',
  room: '101',
  capacity: 40,
  requester: 'Requester',
  role: 'User',
  org: 'Test Unit',
  purpose: 'Cancellation regression test.',
  date: 'Test date',
  start: '09:00',
  end: '10:00',
  heads: 10,
  submitted: 'Now',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.pending,
  occurrences: occurrences,
);

void main() {
  test('browsable facilities include unavailable public listings', () {
    final state = AppState();
    addTearDown(state.dispose);
    final activeUnassigned = state.facilities[0]
      ..state = FacilityState.active
      ..publicListing = true
      ..bookableForCurrentUser = false;
    final maintenance = state.facilities[1]
      ..state = FacilityState.maintenance
      ..publicListing = true;
    final draft = state.facilities[2]
      ..state = FacilityState.draft
      ..publicListing = true;
    final private = state.facilities[3]
      ..state = FacilityState.active
      ..publicListing = false;

    expect(state.browsableFacilities, contains(activeUnassigned));
    expect(state.browsableFacilities, contains(maintenance));
    expect(state.browsableFacilities, isNot(contains(draft)));
    expect(state.browsableFacilities, isNot(contains(private)));
    expect(state.bookableFacilities, isNot(contains(activeUnassigned)));
    expect(state.bookableFacilities, isNot(contains(maintenance)));
  });

  test('browse search and assistant search retain separate scopes', () {
    final state = AppState();
    addTearDown(state.dispose);
    final unavailable = state.facilities.first
      ..state = FacilityState.active
      ..publicListing = true
      ..bookableForCurrentUser = false;

    expect(
      state.searchBrowsableFacilities(query: unavailable.name),
      contains(unavailable),
    );
    expect(state.searchFacilities(query: unavailable.name), isEmpty);
  });

  test(
    'cancellation eligibility excludes past and lifecycle-terminal dates',
    () {
      final state = AppState();
      addTearDown(state.dispose);
      final now = DateTime(2030, 1, 1, 12);
      final request = _requestWithOccurrences([
        ReservationOccurrence(
          id: 'past',
          startsAt: now.subtract(const Duration(hours: 1)),
          endsAt: now,
        ),
        ReservationOccurrence(
          id: 'checked-in',
          startsAt: now.add(const Duration(days: 1)),
          endsAt: now.add(const Duration(days: 1, hours: 1)),
          bookingState: 'booked',
          stage: BookingStage.checkedIn,
        ),
        ReservationOccurrence(
          id: 'future',
          startsAt: now.add(const Duration(days: 2)),
          endsAt: now.add(const Duration(days: 2, hours: 1)),
        ),
      ]);

      expect(
        state.canCancelOccurrence(request, request.occurrences[0], now: now),
        isFalse,
      );
      expect(
        state.canCancelOccurrence(request, request.occurrences[1], now: now),
        isFalse,
      );
      expect(
        state.canCancelOccurrence(request, request.occurrences[2], now: now),
        isTrue,
      );
    },
  );

  test(
    'demo cancellation updates a date and closes the final future date',
    () async {
      final state = AppState();
      addTearDown(state.dispose);
      final start = DateTime.now().add(const Duration(days: 10));
      final request = _requestWithOccurrences([
        ReservationOccurrence(
          id: 'first',
          startsAt: start,
          endsAt: start.add(const Duration(hours: 1)),
        ),
        ReservationOccurrence(
          id: 'second',
          startsAt: start.add(const Duration(days: 1)),
          endsAt: start.add(const Duration(days: 1, hours: 1)),
        ),
      ]);

      expect(
        await state.cancelReservation(request, occurrenceId: 'first'),
        isTrue,
      );
      expect(request.occurrences.first.bookingState, 'cancelled');
      expect(request.status, RequestStatus.pending);

      expect(await state.cancelReservation(request), isTrue);
      expect(request.occurrences.last.bookingState, 'cancelled');
      expect(request.status, RequestStatus.cancelled);
      expect(request.lifecycleStatus, ReservationLifecycleStatus.cancelled);
    },
  );

  test(
    'demo cancellation keeps a series active while a date is checked in',
    () async {
      final state = AppState();
      addTearDown(state.dispose);
      final start = DateTime.now().add(const Duration(days: 10));
      final request = _requestWithOccurrences([
        ReservationOccurrence(
          id: 'cancellable',
          startsAt: start,
          endsAt: start.add(const Duration(hours: 1)),
        ),
        ReservationOccurrence(
          id: 'checked-in',
          startsAt: start.add(const Duration(hours: 2)),
          endsAt: start.add(const Duration(hours: 3)),
          bookingState: 'booked',
          stage: BookingStage.checkedIn,
        ),
      ]);

      expect(
        await state.cancelReservation(request, occurrenceId: 'cancellable'),
        isTrue,
      );
      expect(request.status, RequestStatus.pending);
      expect(
        request.lifecycleStatus,
        ReservationLifecycleStatus.pendingApproval,
      );
    },
  );
}
