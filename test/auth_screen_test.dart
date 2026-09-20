import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/auth/auth_controller.dart';
import 'package:smartreserve/features/auth/auth_screen.dart';
import 'package:smartreserve/theme/sr_theme.dart';

Future<void> _pumpAuth(
  WidgetTester tester, {
  required AuthController controller,
  required AppState state,
}) async {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: SrThemeData.light(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          SrThemeBridge(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: AuthScreen(controller: controller, state: state),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('sign in links outside renters to account creation', (
    tester,
  ) async {
    final state = AppState();
    final controller = AuthController(state);

    await _pumpAuth(tester, controller: controller, state: state);

    expect(
      find.textContaining('Sign in to manage your reservations and payments'),
      findsOneWidget,
    );
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.textContaining('confirmation code'), findsNothing);
    expect(find.textContaining('six-digit'), findsNothing);
    expect(find.textContaining('reset code'), findsNothing);

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Reset your password'), findsOneWidget);
    expect(find.text('Send code'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your renter account'), findsOneWidget);
    expect(find.text('Create renter account'), findsOneWidget);
    expect(find.text('Full name'), findsOneWidget);
  });

  testWidgets('initial temporary password screen is available', (tester) async {
    final state = AppState();
    final controller = AuthController(state)..goTo(AuthStep.initialPassword);

    await _pumpAuth(tester, controller: controller, state: state);

    expect(find.text('Set your account password'), findsOneWidget);
    expect(
      find.text(
        'Your Internal Admin issued temporary credentials. Create a private password before continuing.',
      ),
      findsOneWidget,
    );
    expect(find.text('Save password and continue'), findsOneWidget);
  });

  testWidgets('password recovery accepts a six-digit email code', (
    tester,
  ) async {
    final state = AppState();
    final controller = AuthController(state)..goTo(AuthStep.passwordResetSent);

    await _pumpAuth(tester, controller: controller, state: state);

    expect(find.text('Six-digit code'), findsOneWidget);
    expect(find.text('Verify code'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(6));

    await tester.enterText(find.byType(TextField).first, '12');
    await tester.tap(find.text('Verify code'));
    await tester.pump();

    expect(
      find.text('Enter the six-digit code from your email.'),
      findsOneWidget,
    );
  });
}
