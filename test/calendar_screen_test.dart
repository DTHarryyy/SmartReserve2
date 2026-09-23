import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/calendar/calendar_screen.dart';
import 'package:smartreserve/model/calendar_event.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/util/campus_calendar.dart';

Future<void> _pumpCalendar(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(390, 844),
  double textScale = 1,
  Widget child = const CalendarScreen(),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(
        theme: SrThemeData.light(),
        debugShowCheckedModeBanner: false,
        builder: (context, appChild) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: SrThemeBridge(child: appChild ?? const SizedBox.shrink()),
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

Finder _monthCell(DateTime day) => find.byKey(
  ValueKey('calendar-month-cell-${day.year}-${day.month}-${day.day}'),
);

ReservationRequest _request({
  required String id,
  required String facility,
  required String date,
  required String start,
  required String end,
}) => ReservationRequest(
  id: id,
  facility: facility,
  building: 'A building with a deliberately long descriptive name',
  room: 'ROOM-101',
  capacity: 40,
  requester: 'Calendar Test User',
  role: 'User',
  org: 'Calendar Test Organization',
  purpose: 'Responsive calendar validation',
  date: date,
  start: start,
  end: end,
  heads: 10,
  submitted: 'now',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.pending,
);

void main() {
  test('month grid range always contains 42 Monday-first days', () {
    final (start, end) = calendarMonthGridRange(DateTime(2026, 7, 26));

    expect(start, DateTime(2026, 6, 29));
    expect(start.weekday, DateTime.monday);
    expect(end, DateTime(2026, 8, 10));
    expect(end.difference(start), const Duration(days: 42));
  });

  for (final width in [320.0, 360.0, 390.0, 430.0, 600.0, 760.0, 1180.0]) {
    testWidgets('month grid lays out seven columns at ${width.toInt()} px', (
      tester,
    ) async {
      final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);

      await _pumpCalendar(tester, state, size: Size(width, 900));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('calendar-month-grid')), findsOneWidget);
      final firstWeek = [
        for (var day = 29; day <= 30; day++) DateTime(2026, 6, day),
        for (var day = 1; day <= 5; day++) DateTime(2026, 7, day),
      ];
      final rects = [
        for (final day in firstWeek) tester.getRect(_monthCell(day)),
      ];
      expect(rects.map((rect) => rect.top).toSet(), hasLength(1));
      expect(
        rects.map((rect) => rect.width.toStringAsFixed(2)).toSet(),
        hasLength(1),
      );
      if (width < 800) {
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          ),
          findsNothing,
        );
      }
    });
  }

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('compact month supports ${scale}x text scaling', (
      tester,
    ) async {
      final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);

      await _pumpCalendar(tester, state, textScale: scale);

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('calendar-month-count-2026-7-28')),
        findsOneWidget,
      );
    });
  }

  testWidgets('short landscape month scrolls to its final week', (
    tester,
  ) async {
    final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);
    await _pumpCalendar(tester, state, size: const Size(568, 320));

    expect(tester.takeException(), isNull);
    final finalCell = _monthCell(DateTime(2026, 8, 9));
    await tester.ensureVisible(finalCell);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(finalCell).dy, lessThanOrEqualTo(320));
  });

  testWidgets('crowded and overnight days use counts and a scrollable sheet', (
    tester,
  ) async {
    final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);
    state.requests.insertAll(0, [
      _request(
        id: 'overnight-calendar-test',
        facility:
            'Extremely Long Facility Name Used to Validate Responsive Rows',
        date: 'Tue 28 Jul',
        start: '23:00',
        end: '01:00',
      ),
      _request(
        id: 'crowded-calendar-test',
        facility: 'Another Long Facility Name for the Crowded Calendar Day',
        date: 'Tue 28 Jul',
        start: '21:00',
        end: '22:00',
      ),
    ]);
    await _pumpCalendar(tester, state, size: const Size(390, 700));

    final july28Count = state.visibleCalendarEvents
        .where((event) => event.overlapsDay(DateTime(2026, 7, 28)))
        .length;
    await tester.tap(_monthCell(DateTime(2026, 7, 28)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('calendar-day-sheet')), findsOneWidget);
    expect(find.text('$july28Count reservations'), findsOneWidget);
    expect(find.textContaining('Extremely Long Facility Name'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Close day reservations'));
    await tester.pumpAndSettle();
    await tester.tap(_monthCell(DateTime(2026, 7, 29)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('calendar-day-event-overnight-calendar-test')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and adjacent days keep the selected month', (
    tester,
  ) async {
    final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);
    await _pumpCalendar(tester, state);

    await tester.tap(_monthCell(DateTime(2026, 6, 29)));
    await tester.pumpAndSettle();

    expect(find.text('No reservations for this date.'), findsOneWidget);
    expect(state.calendarViewMode, CalendarViewMode.month);
    expect(state.calendarAnchor.month, 7);

    await tester.tap(find.byTooltip('Close day reservations'));
    await tester.pumpAndSettle();
    expect(find.text('Jul 2026'), findsOneWidget);
  });

  testWidgets('day event selection opens existing mobile details', (
    tester,
  ) async {
    final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);
    await _pumpCalendar(tester, state);

    await tester.tap(_monthCell(DateTime(2026, 7, 28)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-day-event-r1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('calendar-day-sheet')), findsNothing);
    expect(find.text('Reservation details'), findsOneWidget);
    expect(state.calendarViewMode, CalendarViewMode.month);
  });

  testWidgets('empty filtered month retains grid and clear action', (
    tester,
  ) async {
    final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);
    state.setCalendarQuery('no reservation can match this query');
    await _pumpCalendar(
      tester,
      state,
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('calendar-month-grid')), findsOneWidget);
    expect(find.byKey(const Key('calendar-empty-noMatches')), findsOneWidget);

    final clearFilters = find.byKey(const Key('calendar-clear-filters'));
    await tester.ensureVisible(clearFilters);
    await tester.pumpAndSettle();
    await tester.tap(clearFilters);
    await tester.pump();
    expect(state.calendarQuery, isEmpty);
  });

  testWidgets('public day sheet keeps masked reservations private', (
    tester,
  ) async {
    final state = AppState()..userCalendarAnchor = DateTime(2026, 7, 26);
    await state.refreshUserCalendar();
    await _pumpCalendar(tester, state, child: const PublicCalendarScreen());

    await tester.tap(_monthCell(DateTime(2026, 7, 28)));
    await tester.pumpAndSettle();

    expect(find.text('Reserved'), findsWidgets);
    expect(find.textContaining('Prof. Bautista'), findsNothing);
    expect(find.textContaining('Nursing orientation'), findsNothing);
    final maskedEvent = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('calendar-day-event-public:');
    });
    expect(maskedEvent, findsWidgets);
    await tester.tap(maskedEvent.first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendar-day-sheet')), findsOneWidget);
    expect(find.text('Reservation details'), findsNothing);
  });

  testWidgets('public month loads reservations on adjacent grid dates', (
    tester,
  ) async {
    final state = AppState()..userCalendarAnchor = DateTime(2026, 7, 26);
    state.bookings.add(
      Booking.fromLabels(
        id: 'adjacent-public-calendar-test',
        facility: 'Computer Laboratory 1',
        date: 'Mon 29 Jun',
        start: '09:00',
        end: '10:00',
        label: 'Adjacent grid reservation',
        requester: 'Private Requester',
      ),
    );
    await state.refreshUserCalendar();

    expect(
      state.userCalendarSlots.any(
        (slot) =>
            slot.startsAt.year == 2026 &&
            slot.startsAt.month == 6 &&
            slot.startsAt.day == 29,
      ),
      isTrue,
    );

    await _pumpCalendar(tester, state, child: const PublicCalendarScreen());
    await tester.tap(_monthCell(DateTime(2026, 6, 29)));
    await tester.pumpAndSettle();

    expect(find.text('1 reservation'), findsOneWidget);
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
    expect(find.textContaining('Private Requester'), findsNothing);
  });

  testWidgets('previous next and today navigation preserve month mode', (
    tester,
  ) async {
    final state = AppState()..calendarAnchor = DateTime(2026, 7, 26);
    await _pumpCalendar(tester, state);

    await tester.tap(find.byKey(const Key('compact-calendar-next')));
    await tester.pump();
    expect(state.calendarAnchor.month, 8);
    expect(state.calendarViewMode, CalendarViewMode.month);

    await tester.tap(find.byKey(const Key('compact-calendar-previous')));
    await tester.pump();
    expect(state.calendarAnchor.month, 7);

    await tester.tap(find.byKey(const Key('compact-calendar-range')));
    await tester.pump();
    expect(state.calendarAnchor, state.calendarToday);
  });
}
