import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/account.dart';

SessionProfile widgetProfile({
  String verificationStatus = 'verified',
  String role = 'user',
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

Future<void> openAssistant(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('student-assistant-tab')));
  await tester.pumpAndSettle();
}

Future<void> sendMessage(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.tap(find.byTooltip('Send'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Assist tab shows a greeting and suggestion chips', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    await openAssistant(tester);

    expect(find.textContaining('Ask me to find a room'), findsOneWidget);
    expect(find.text('What facilities are available?'), findsOneWidget);
    expect(find.text('Show my reservations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the exact example phrase surfaces a matching facility', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);
    await openAssistant(tester);

    await sendMessage(
      tester,
      'i want to book for 50-60 person with arcoin an and seats on auges 20',
    );

    expect(find.text('University Auditorium'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '"what are the available facilities" lists the bookable catalogue',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await state.applyBackendProfile(widgetProfile());
      await pumpStudentApp(tester, state: state);
      await openAssistant(tester);

      await sendMessage(tester, 'what are the available facilities');

      expect(find.text('Computer Laboratory 1'), findsWidgets);
      expect(find.text('Faculty Conference Room'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a full slot-filling conversation books a reservation', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);
    await openAssistant(tester);

    expect(state.myRequests, isEmpty);

    await sendMessage(tester, 'book the auditorium for 30 people');
    expect(find.textContaining('What date works'), findsOneWidget);

    await sendMessage(tester, 'tomorrow');
    expect(find.textContaining("What time"), findsOneWidget);

    await sendMessage(tester, '2pm to 4pm');
    expect(find.textContaining("What's it for"), findsOneWidget);

    await sendMessage(tester, 'org general assembly');
    expect(find.text('Ready to send'), findsOneWidget);
    expect(find.text('Confirm request'), findsOneWidget);

    await tester.tap(find.text('Confirm request'));
    await tester.pumpAndSettle();

    expect(state.myRequests.length, 1);
    expect(state.myRequests.first.facility, 'University Auditorium');
    expect(find.textContaining('Sent.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a suspended account is blocked at confirm, not before', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    state.userAccount.status = AccountStatus.suspended;
    await pumpStudentApp(tester, state: state);
    await openAssistant(tester);

    await sendMessage(tester, 'book the auditorium for 30 people');
    await sendMessage(tester, 'tomorrow');
    await sendMessage(tester, '2pm to 4pm');
    await sendMessage(tester, 'org general assembly');
    expect(find.text('Confirm request'), findsOneWidget);

    await tester.tap(find.text('Confirm request'));
    await tester.pumpAndSettle();

    expect(state.myRequests, isEmpty);
    expect(find.textContaining('suspended'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"show my reservations" lists what the student has booked', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);
    await openAssistant(tester);

    await sendMessage(tester, 'book the auditorium for 30 people');
    await sendMessage(tester, 'tomorrow');
    await sendMessage(tester, '2pm to 4pm');
    await sendMessage(tester, 'org general assembly');
    await tester.tap(find.text('Confirm request'));
    await tester.pumpAndSettle();

    await sendMessage(tester, 'show my reservations');
    expect(find.text('University Auditorium'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('renders without overflow on a small phone', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state, size: const Size(360, 760));
    await openAssistant(tester);

    await sendMessage(tester, 'what are the available facilities');
    expect(tester.takeException(), isNull);
  });
}
