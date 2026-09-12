import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/theme/sr_theme.dart';

Future<void> _pumpStudentAccount(
  WidgetTester tester,
  AppState state, {
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
        home: const Scaffold(body: StudentApp()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Account').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('account dashboard uses the available desktop width', (
    tester,
  ) async {
    final state = AppState()..signInAsUser('u5');

    await _pumpStudentAccount(tester, state, size: const Size(1440, 900));

    expect(find.text('BOOKING ACCESS'), findsOneWidget);
    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text('Account actions'), findsOneWidget);
    expect(find.text('Security'), findsNothing);
    expect(find.text('Changed 3 months ago'), findsNothing);
    expect(find.text('Expires in 30 days'), findsNothing);

    final overview = tester.getSize(
      find.byKey(const Key('student-account-overview')),
    );
    expect(overview.width, greaterThan(1080));
  });

  testWidgets('guest accounts omit empty campus profile fields', (
    tester,
  ) async {
    final state = AppState()..signInAsUser('u5');
    state.sessionProfile = const SessionProfile(
      id: 'u5',
      email: 'council.macanaya@gmail.com',
      fullName: 'Aparri Barangay Council',
      role: 'user',
      campusClaim: 'none',
      campusId: null,
      unit: '',
      verificationStatus: 'none',
      onboardingComplete: true,
      accountStatus: 'active',
      accountAccessType: 'external_guest',
      mustChangePassword: false,
      createdAt: null,
    );

    await _pumpStudentAccount(tester, state, size: const Size(430, 900));

    expect(find.text('Profile details'), findsNothing);
    expect(find.text('Account actions'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });
}
