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

  group('responsive authentication shell', () {
    Future<void> pumpAt(
      WidgetTester tester,
      Size size,
      AuthController controller,
      AppState state,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuthScreen(controller: controller, state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('mobile uses focused form with improved placeholders', (
      tester,
    ) async {
      final state = AppState();
      final controller = AuthController(state);
      addTearDown(controller.dispose);
      await pumpAt(tester, const Size(390, 844), controller, state);

      expect(find.text('Sign in to SmartReserve'), findsOneWidget);
      expect(find.text('name@example.com'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
      expect(find.text('Every room, pinned'), findsNothing);

      final fields = find.byType(TextField);
      final emailBox = find.ancestor(
        of: fields.at(0),
        matching: find.byType(AnimatedContainer),
      );
      final passwordBox = find.ancestor(
        of: fields.at(1),
        matching: find.byType(AnimatedContainer),
      );
      expect(
        tester.getSize(passwordBox).height,
        tester.getSize(emailBox).height,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('tablet shows the compact campus banner', (tester) async {
      final state = AppState();
      final controller = AuthController(state);
      addTearDown(controller.dispose);
      await pumpAt(tester, const Size(800, 1280), controller, state);

      expect(
        find.text('Every campus space, easier to find and reserve.'),
        findsOneWidget,
      );
      expect(find.text('Every room, pinned'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop uses the full supporting panel', (tester) async {
      final state = AppState();
      final controller = AuthController(state);
      addTearDown(controller.dispose);
      await pumpAt(tester, const Size(1440, 900), controller, state);

      expect(find.text('Every room, pinned'), findsOneWidget);
      expect(find.text('Sign in to SmartReserve'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop centers the form card vertically in the right pane', (
      tester,
    ) async {
      final state = AppState();
      final controller = AuthController(state);
      addTearDown(controller.dispose);
      await pumpAt(tester, const Size(1440, 900), controller, state);

      final card = find.ancestor(
        of: find.text('Sign in to SmartReserve'),
        matching: find.byType(AnimatedSwitcher),
      );
      final cardCenter = tester.getCenter(card);
      expect(cardCenter.dy, closeTo(900 / 2, 24));
      expect(tester.takeException(), isNull);
    });

    testWidgets('reset flow includes code and password confirmation', (
      tester,
    ) async {
      final state = AppState();
      final controller = AuthController(state)
        ..emailField.text = 'student@example.com'
        ..goTo(AuthStep.reset);
      addTearDown(controller.dispose);
      await pumpAt(tester, const Size(390, 844), controller, state);

      expect(find.text('Enter your reset code'), findsOneWidget);
      expect(find.text('Create a new passphrase'), findsOneWidget);
      expect(find.text('Enter the new password again'), findsOneWidget);
      expect(find.text('Edit email address'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
