import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/calendar/calendar_screen.dart';
import 'package:smartreserve/features/student/loyalty_page.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/facility.dart';
import 'package:smartreserve/theme/sr_theme.dart';

Future<void> _pumpScoped(
  WidgetTester tester,
  AppState state,
  Widget child, {
  required Size size,
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
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: child,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openAccountTab(WidgetTester tester) async {
  await tester.tap(find.text('Account').last);
  await tester.pumpAndSettle();
}

Future<void> _openCalendarTab(WidgetTester tester) async {
  await tester.tap(find.text('Calendar').last);
  await tester.pumpAndSettle();
}

FlutterExceptionHandler? _collectFlutterErrors(
  List<FlutterErrorDetails> errors,
) {
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  return previous;
}

void _restoreFlutterErrors(FlutterExceptionHandler? previous) {
  FlutterError.onError = previous;
}

void _makeGymplexCardDemanding(AppState state) {
  final gymplex = state.facilities.firstWhere((item) => item.id == 'f5');
  gymplex
    ..name = 'Gymplex'
    ..capacity = 4000
    ..hours = '08:00-19:00'
    ..days = 'Mon-Sun'
    ..state = FacilityState.active
    ..amenities = ['Power Outlets']
    ..ratingAverage = 4.8
    ..ratingCount = 124;
}

void main() {
  testWidgets('loyalty entry points are visible only for guest-priced renters', (
    tester,
  ) async {
    final verified = AppState();
    await verified.refreshLoyalty();
    await _pumpScoped(
      tester,
      verified,
      const StudentApp(),
      size: const Size(900, 760),
    );

    expect(find.byKey(const Key('student-loyalty-chip')), findsNothing);
    await _openAccountTab(tester);
    expect(find.byKey(const Key('student-loyalty-entry')), findsNothing);

    final guest = AppState()..signInAsUser('u5');
    await _pumpScoped(
      tester,
      guest,
      const StudentApp(),
      size: const Size(900, 760),
    );

    expect(find.byKey(const Key('student-loyalty-chip')), findsOneWidget);
    await _openAccountTab(tester);
    expect(find.byKey(const Key('student-loyalty-entry')), findsOneWidget);

    final pending = AppState()..signInAsUser('u3');
    await _pumpScoped(
      tester,
      pending,
      const StudentApp(),
      size: const Size(900, 760),
    );

    expect(find.byKey(const Key('student-loyalty-chip')), findsOneWidget);
  });

  testWidgets('stale loyalty navigation for verified renters shows unavailable', (
    tester,
  ) async {
    final state = AppState();
    await state.refreshLoyalty();

    await _pumpScoped(
      tester,
      state,
      const LoyaltyPage(),
      size: const Size(430, 760),
    );

    expect(find.text('Loyalty is available to guest renters'), findsOneWidget);
    expect(find.text('Available balance'), findsNothing);
    expect(find.text('Redeem'), findsNothing);
  });

  testWidgets('browse cards with ratings and amenities do not overflow compact', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = _collectFlutterErrors(errors);
    addTearDown(() => _restoreFlutterErrors(previous));

    final state = AppState();
    _makeGymplexCardDemanding(state);

    await _pumpScoped(
      tester,
      state,
      const StudentApp(),
      size: const Size(430, 760),
    );

    expect(find.text('Gymplex'), findsOneWidget);
    expect(
      errors.where(
        (error) => error.exceptionAsString().contains('RenderFlex overflowed'),
      ),
      isEmpty,
    );
  });

  testWidgets('browse cards with ratings and amenities do not overflow desktop', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = _collectFlutterErrors(errors);
    addTearDown(() => _restoreFlutterErrors(previous));

    final state = AppState();
    _makeGymplexCardDemanding(state);

    await _pumpScoped(
      tester,
      state,
      const StudentApp(),
      size: const Size(1180, 840),
    );

    expect(find.text('Gymplex'), findsOneWidget);
    expect(
      errors.where(
        (error) => error.exceptionAsString().contains('RenderFlex overflowed'),
      ),
      isEmpty,
    );
  });

  testWidgets('calendar tab is available for active users in every verification state', (
    tester,
  ) async {
    for (final userId in ['u1', 'u3', 'u5', 'u6']) {
      final state = AppState()..signInAsUser(userId);
      await _pumpScoped(
        tester,
        state,
        const StudentApp(),
        size: const Size(900, 760),
      );

      expect(find.text('Calendar'), findsWidgets);
    }
  });

  testWidgets('public calendar masks reservation details on compact layout', (
    tester,
  ) async {
    final state = AppState();
    state.userCalendarAnchor = DateTime(2026, 7, 28);
    await state.refreshUserCalendar();

    await _pumpScoped(
      tester,
      state,
      const StudentApp(),
      size: const Size(430, 760),
    );
    await _openCalendarTab(tester);

    expect(find.text('Reserved'), findsWidgets);
    expect(find.textContaining('Prof. Bautista'), findsNothing);
    expect(find.textContaining('IT 3A'), findsNothing);
    expect(find.textContaining('Nursing orientation'), findsNothing);
    expect(find.textContaining('Dean Villamor'), findsNothing);

    await tester.tap(find.text('Reserved').first);
    await tester.pumpAndSettle();
    expect(find.text('Reservation details'), findsNothing);
    expect(find.text('Open reservation'), findsNothing);
  });

  testWidgets('public calendar facility filter refreshes visible slots', (
    tester,
  ) async {
    final state = AppState();
    state.userCalendarAnchor = DateTime(2026, 7, 28);
    await state.refreshUserCalendar();

    await _pumpScoped(
      tester,
      state,
      const PublicCalendarScreen(),
      size: const Size(430, 760),
    );

    expect(find.textContaining('Computer Laboratory 1'), findsWidgets);

    state.setUserCalendarFacilityFilter('University Auditorium');
    await tester.pumpAndSettle();

    expect(find.textContaining('University Auditorium'), findsWidgets);
    expect(find.textContaining('Computer Laboratory 1'), findsNothing);
  });

  testWidgets('admin calendar keeps reservation controls', (tester) async {
    final state = AppState();

    await _pumpScoped(
      tester,
      state,
      const CalendarScreen(),
      size: const Size(1180, 840),
    );

    expect(find.text('Search reservations'), findsOneWidget);
    expect(find.text('Needs decision'), findsWidgets);
    expect(find.text('Confirmed'), findsWidgets);
  });
}
