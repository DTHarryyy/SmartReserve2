import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/features/calendar/calendar_screen.dart';
import 'package:smartreserve/model/calendar_event.dart';
import 'package:smartreserve/model/reservation.dart';

void main() {
  group('central calendar', () {
    test('uses active and pending occurrences by default', () {
      final state = AppState();

      expect(
        state.visibleCalendarEvents.map((event) => event.id),
        containsAll(['r1', 'r7', 'b1']),
      );
      expect(
        state.visibleCalendarEvents.map((event) => event.id),
        isNot(contains('r8')),
      );
    });

    test('projects every occurrence in a recurring request', () {
      final state = AppState();
      final request = state.requests.firstWhere(
        (request) => request.id == 'r3',
      );
      request.occurrences.addAll([
        ReservationOccurrence(
          id: 'r3-a',
          startsAt: DateTime(2026, 7, 28, 13),
          endsAt: DateTime(2026, 7, 28, 15),
        ),
        ReservationOccurrence(
          id: 'r3-b',
          startsAt: DateTime(2026, 8, 4, 13),
          endsAt: DateTime(2026, 8, 4, 15),
        ),
      ]);

      final series = state.calendarEvents
          .where((event) => event.requestId == 'r3')
          .toList();
      expect(series, hasLength(2));
      expect(series.map((event) => event.startsAt.month), containsAll([7, 8]));
    });

    test('filters by facility, status, and reservation text', () {
      final state = AppState();
      state.setCalendarFacilityFilter('University Auditorium');
      state.setCalendarQuery('elena');

      expect(state.visibleCalendarEvents, hasLength(1));
      expect(
        state.visibleCalendarEvents.single.requester,
        'Prof. Elena Sarmiento',
      );

      state.toggleCalendarState(CalendarEventState.declined);
      state.setCalendarQuery('product launch');
      expect(
        state.visibleCalendarEvents.single.state,
        CalendarEventState.declined,
      );
    });

    test(
      'calendar treats cross-midnight occurrences as present on both days',
      () {
        final state = AppState();
        final request = state.requests.firstWhere(
          (request) => request.id == 'r1',
        );
        request.occurrences.add(
          ReservationOccurrence(
            id: 'overnight',
            startsAt: DateTime(2026, 8, 1, 23),
            endsAt: DateTime(2026, 8, 2, 1),
          ),
        );

        final event = state.calendarEvents.singleWhere(
          (item) => item.occurrenceId == 'overnight',
        );
        expect(event.overlapsDay(DateTime(2026, 8, 1)), isTrue);
        expect(event.overlapsDay(DateTime(2026, 8, 2)), isTrue);
      },
    );

    test('navigates all seven days and opens a request in the queue', () {
      final state = AppState();
      state.selectCalendarDate(DateTime(2026, 8, 2));
      expect(state.calendarAnchor.weekday, DateTime.sunday);

      state.setCalendarViewMode(CalendarViewMode.week);
      state.navigateCalendar(1);
      expect(state.calendarAnchor, DateTime(2026, 8, 9));

      final event = state.calendarEvents.firstWhere(
        (item) => item.requestId == 'r7',
      );
      state.openRequestFromCalendar(event);
      expect(state.view, AppView.reservations);
      expect(state.requestTab, RequestStatus.approved);
      expect(state.selectedRequestId, 'r7');
    });
  });

  testWidgets('calendar opens details and hands a request back to the queue', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    state.selectCalendarEvent('r1');
    await tester.pumpAndSettle();

    expect(find.text('Reservation details'), findsOneWidget);
    await tester.ensureVisible(find.text('Open reservation'));
    await tester.tap(find.text('Open reservation'));
    expect(state.view, AppView.reservations);
    expect(state.selectedRequestId, 'r1');
    state.dispose();
  });

  testWidgets('calendar renders week and day views', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    state.setCalendarViewMode(CalendarViewMode.week);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    state.setCalendarViewMode(CalendarViewMode.day);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    state.dispose();
  });
}
