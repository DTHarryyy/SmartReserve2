import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/facility_photo.dart';
import 'package:smartreserve/widgets/filter_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

SessionProfile widgetProfile({
  String verificationStatus = 'verified',
  String role = 'student',
}) => SessionProfile(
  id: '00000000-0000-0000-0000-000000000100',
  email: 'roel@example.com',
  fullName: 'Roel Dela Cruz',
  role: role,
  campusClaim: 'student',
  campusId: '2026-00123',
  unit: 'BS Information Technology',
  verificationStatus: verificationStatus,
  onboardingComplete: true,
  accountStatus: 'active',
  createdAt: DateTime.utc(2026, 8, 7, 12),
);

Future<void> pumpStudentApp(
  WidgetTester tester, {
  required AppState state,
  Size size = const Size(1200, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: const MaterialApp(home: Scaffold(body: StudentApp())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('desktop uses the simple identity header and bottom navigation', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    expect(find.text('Roel Dela Cruz'), findsOneWidget);
    expect(find.text('roel@example.com'), findsOneWidget);
    expect(find.text('VERIFIED'), findsOneWidget);
    expect(find.text('You are verified'), findsOneWidget);
    expect(find.text('Admin'), findsNothing);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Your details'), findsOneWidget);
  });

  testWidgets('verification banners can be dismissed permanently', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    expect(find.text('You are verified'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss membership message'));
    await tester.pumpAndSettle();
    expect(find.text('You are verified'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpStudentApp(tester, state: state);
    expect(find.text('You are verified'), findsNothing);
  });

  testWidgets('mobile keeps name and email with a compact pending badge', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(
      widgetProfile(verificationStatus: 'pending'),
    );
    await pumpStudentApp(tester, state: state, size: const Size(360, 760));

    expect(find.text('Roel Dela Cruz'), findsOneWidget);
    expect(find.text('roel@example.com'), findsOneWidget);
    expect(find.text('IN PROCESS'), findsOneWidget);
    expect(find.text('Verification in process'), findsOneWidget);
    expect(find.text('You are booking at the external rate'), findsNothing);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    final category = find.byWidgetPredicate(
      (widget) =>
          widget is FilterSelect &&
          widget.semanticLabel == 'Filter by category',
    );
    final capacity = find.byWidgetPredicate(
      (widget) =>
          widget is FilterSelect &&
          widget.semanticLabel == 'Filter by minimum capacity',
    );
    expect(category, findsOneWidget);
    expect(capacity, findsOneWidget);
    final categoryRect = tester.getRect(category);
    final capacityRect = tester.getRect(capacity);
    final amenitiesRect = tester.getRect(find.text('Amenities'));
    expect(categoryRect.top, capacityRect.top);
    expect(categoryRect.center.dy, closeTo(amenitiesRect.center.dy, 2));
    expect(categoryRect.width, closeTo(capacityRect.width, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('external users do not see a membership banner', (tester) async {
    final state = AppState();
    await state.applyBackendProfile(
      widgetProfile(verificationStatus: 'none', role: 'guest'),
    );
    await pumpStudentApp(tester, state: state);

    expect(find.text('You are verified'), findsNothing);
    expect(find.text('Verification in process'), findsNothing);
  });

  testWidgets('facility filters combine and clear correctly', (tester) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    expect(find.text('5 of 5'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'auditorium');
    await tester.pump();
    expect(find.text('University Auditorium'), findsOneWidget);
    expect(find.text('Computer Laboratory 1'), findsNothing);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    await tester.tap(find.text('Any capacity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('500+ seats').last);
    await tester.pumpAndSettle();
    expect(find.text('Main Court'), findsOneWidget);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    await tester.tap(find.text('Amenities'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projector').last);
    await tester.pumpAndSettle();
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
    expect(find.text('University Auditorium'), findsOneWidget);

    await tester.tap(find.text('Amenities (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Power Outlets').last);
    await tester.pumpAndSettle();
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
    expect(find.text('University Auditorium'), findsNothing);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    expect(find.text('5 of 5'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'does not exist');
    await tester.pump();
    expect(find.text('No facilities match'), findsOneWidget);

    await tester.tap(find.text('Clear filters').last);
    await tester.pump();
    expect(find.text('5 of 5'), findsNothing);
  });

  testWidgets('category filter narrows the facility catalogue', (tester) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auditorium').last);
    await tester.pumpAndSettle();

    expect(find.text('University Auditorium'), findsOneWidget);
    expect(find.text('Main Court'), findsNothing);
  });

  testWidgets('facility dialog shows every photo and booking detail', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    final facility = state.facilities.first;
    facility.photos = [
      FacilityPhoto.placeholder(11),
      FacilityPhoto.placeholder(12),
      FacilityPhoto.placeholder(13),
    ];
    facility.street = 'University Avenue';
    facility.barangay = 'Macanaya';
    facility.municipality = 'Aparri';
    facility.province = 'Cagayan';
    facility.region = 'Region II';
    facility.country = 'Philippines';

    await pumpStudentApp(tester, state: state);
    await tester.tap(find.text('Computer Laboratory 1'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.text('1 / 3 PHOTOS'), findsOneWidget);
    expect(find.text('Facility details'), findsOneWidget);
    expect(find.text('Request this facility'), findsOneWidget);
    expect(find.text('07:00–19:00'), findsOneWidget);
    expect(find.text('30 days ahead'), findsOneWidget);
    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.textContaining('University Avenue'), findsOneWidget);
    expect(find.text('Open map ↗'), findsOneWidget);
    expect(find.text('PWD Accessibility'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('facility-photo-thumbnail-1')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3 PHOTOS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('facility opens as a back-enabled page on a small phone', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    state.facilities.first.photos = [
      FacilityPhoto.placeholder(21),
      FacilityPhoto.placeholder(22),
    ];

    await pumpStudentApp(tester, state: state, size: const Size(360, 760));
    await tester.tap(find.text('Computer Laboratory 1'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.text('1 / 2 PHOTOS'), findsOneWidget);
    expect(find.text('Facility details'), findsOneWidget);
    expect(find.text('Request this facility'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final dateRect = tester.getRect(find.text('Date'));
    final attendeesRect = tester.getRect(find.text('Attendees'));
    final fromRect = tester.getRect(find.text('From'));
    final toRect = tester.getRect(find.text('To'));
    expect(dateRect.top, closeTo(attendeesRect.top, 1));
    expect(fromRect.top, closeTo(toRect.top, 1));

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
  });
}
