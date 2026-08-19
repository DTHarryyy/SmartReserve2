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

    test('resets calendar filters to their defaults', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.setCalendarFacilityFilter('University Auditorium');
      state.setCalendarQuery('elena');
      state.toggleCalendarState(CalendarEventState.confirmed);

      state.resetCalendarFilters();

      expect(state.calendarFacilityFilter, 'All facilities');
      expect(state.calendarQuery, isEmpty);
      expect(state.calendarStates, equals(CalendarEventState.defaultVisible));
      expect(state.visibleCalendarEvents, isNotEmpty);
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

  testWidgets('compact toolbar keeps navigation and filters in single rows', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final size in const [
      Size(320, 720),
      Size(375, 812),
      Size(390, 844),
      Size(480, 840),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(
            state: state,
            child: const Scaffold(body: CalendarScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final navigation = tester.getRect(
        find.byKey(const Key('compact-calendar-navigation')),
      );
      final search = tester.getRect(
        find.byKey(const Key('compact-calendar-search')),
      );
      final filters = tester.getRect(
        find.byKey(const Key('compact-calendar-filters')),
      );
      final range = tester.getRect(
        find.byKey(const Key('compact-calendar-range')),
      );
      final monthCenter = tester.getCenter(find.text('Month'));
      final weekCenter = tester.getCenter(find.text('Week'));
      final dayCenter = tester.getCenter(find.text('Day'));

      expect(navigation.height, 44);
      expect(find.byKey(const Key('compact-calendar-range')), findsOneWidget);
      expect(monthCenter.dy, closeTo(weekCenter.dy, 0.1));
      expect(weekCenter.dy, closeTo(dayCenter.dy, 0.1));
      expect(
        weekCenter.dx - monthCenter.dx,
        closeTo(dayCenter.dx - weekCenter.dx, 1),
      );
      expect(search.left, lessThan(filters.left));
      expect(search.top, filters.top);
      expect(search.bottom, filters.bottom);
      expect(search.height, 44);
      expect(filters.height, 44);
      expect(range.width, lessThanOrEqualTo(64));
      expect(find.textContaining('shown'), findsNothing);
      expect(find.text('Today'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('expanded toolbar retains the visible reservation count', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('shown'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty calendar directs administrators to reservation requests', (
    tester,
  ) async {
    final state = AppState()
      ..requests.clear()
      ..bookings.clear();
    addTearDown(state.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No reservations yet'), findsOneWidget);
    expect(find.byKey(const Key('calendar-empty-noData')), findsOneWidget);
    await tester.tap(find.text('View reservation requests'));
    expect(state.view, AppView.reservations);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtered empty state clears search and restores reservations', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'no such reservation');
    await tester.pumpAndSettle();

    expect(find.text('No reservations match your filters'), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-clear-filters')));
    await tester.pumpAndSettle();

    expect(state.calendarQuery, isEmpty);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(find.text('No reservations match your filters'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop empty range keeps its grid and offers useful recovery', (
    tester,
  ) async {
    final state = AppState()..selectCalendarDate(DateTime(2040, 1, 1));
    addTearDown(state.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 900);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No reservations this month'), findsOneWidget);
    expect(find.text('MON'), findsOneWidget);
    expect(find.byKey(const Key('calendar-go-to-today')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-go-to-today')));
    await tester.pumpAndSettle();
    expect(state.calendarAnchor, state.calendarToday);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty current day does not offer a redundant today action', (
    tester,
  ) async {
    final state = AppState()..setCalendarViewMode(CalendarViewMode.day);
    state.selectCalendarDate(state.calendarToday);
    addTearDown(state.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: CalendarScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No reservations this day'), findsOneWidget);
    expect(find.byKey(const Key('calendar-go-to-today')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
