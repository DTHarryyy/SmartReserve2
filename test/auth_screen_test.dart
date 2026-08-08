import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/auth/auth_controller.dart';
import 'package:smartreserve/features/auth/auth_screen.dart';

void main() {
  test('sign in is the default authentication screen', () {
    final state = AppState();
    final controller = AuthController(state);
    addTearDown(controller.dispose);

    expect(controller.step, AuthStep.signIn);
  });

  test(
    'sign in accepts an existing password shorter than ten characters',
    () async {
      final state = AppState();
      final controller = AuthController(state)
        ..emailField.text = 'admin@csu.edu.ph'
        ..passwordField.text = 'admin123';
      addTearDown(controller.dispose);

      await controller.submitSignIn();

      expect(controller.passwordError, isNull);
      expect(controller.operationError, isNotNull);
    },
  );

  test('ending a session clears auth data and returns to sign in', () async {
    final state = AppState();
    await state.applyBackendProfile(
      SessionProfile(
        id: '00000000-0000-0000-0000-000000000123',
        email: 'admin@csu.edu.ph',
        fullName: 'CSU Internal Admin',
        role: 'internal_admin',
        campusClaim: null,
        campusId: null,
        unit: null,
        verificationStatus: 'verified',
        onboardingComplete: true,
        accountStatus: 'active',
        createdAt: DateTime.utc(2026, 8, 7),
      ),
    );
    final controller = AuthController(state)
      ..emailField.text = 'admin@csu.edu.ph'
      ..passwordField.text = 'admin123'
      ..goTo(AuthStep.signUp);
    addTearDown(controller.dispose);

    await state.applyBackendProfile(null);

    expect(controller.step, AuthStep.signIn);
    expect(controller.emailField.text, isEmpty);
    expect(controller.passwordField.text, isEmpty);
    expect(state.hasSession, isFalse);
    expect(state.view, AppView.auth);
  });

  testWidgets('onboarding does not offer a route to the admin console', (
    tester,
  ) async {
    final state = AppState();
    final controller = AuthController(state);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthScreen(controller: controller, state: state),
        ),
      ),
    );

    expect(find.text('Back to admin'), findsNothing);
    expect(find.text('SmartReserve'), findsOneWidget);
  });
}
