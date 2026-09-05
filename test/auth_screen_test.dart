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
      home: AuthScreen(controller: controller, state: state),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('sign in has no public signup or reset-email actions', (
    tester,
  ) async {
    final state = AppState();
    final controller = AuthController(state);

    await _pumpAuth(tester, controller: controller, state: state);

    expect(
      find.text(
        'Organization accounts are issued by an Internal Admin. Contact your organization administrator to request access.',
      ),
      findsOneWidget,
    );
    expect(find.text('Create account'), findsNothing);
    expect(find.text('Create an account'), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.textContaining('Need a password reset?'), findsOneWidget);
    expect(find.textContaining('confirmation code'), findsNothing);
    expect(find.textContaining('six-digit'), findsNothing);
    expect(find.textContaining('reset code'), findsNothing);
  });

  testWidgets('initial temporary password screen is available', (
    tester,
  ) async {
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
}
