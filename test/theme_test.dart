import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_shell.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/main.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/theme/sr_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('theme preference defaults to the system setting', () async {
    final state = AppState();
    await state.loadThemePreference();

    expect(state.themePreference, SrThemePreference.system);
    expect(state.themePreference.themeMode, ThemeMode.system);
  });

  test('theme preference is restored and persisted locally', () async {
    SharedPreferences.setMockInitialValues({'sr.theme_mode.v1': 'dark'});
    final state = AppState();
    await state.loadThemePreference();

    expect(state.themePreference, SrThemePreference.dark);

    await state.setThemePreference(SrThemePreference.light);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('sr.theme_mode.v1'), 'light');
  });

  testWidgets('switching preference rebuilds the active application theme', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      AnimatedBuilder(
        animation: state,
        builder: (context, _) => MaterialApp(
          theme: SrThemeData.light(),
          darkTheme: SrThemeData.dark(),
          themeMode: state.themePreference.themeMode,
          builder: (context, child) => SrThemeBridge(child: child!),
          home: const _ThemeProbe(),
        ),
      ),
    );

    await state.setThemePreference(SrThemePreference.dark);
    await tester.pumpAndSettle();

    final darkContext = tester.element(find.byKey(const Key('theme-probe')));
    expect(Theme.of(darkContext).brightness, Brightness.dark);
    expect(darkContext.srColors, SrColors.dark);

    await state.setThemePreference(SrThemePreference.light);
    await tester.pumpAndSettle();

    final lightContext = tester.element(find.byKey(const Key('theme-probe')));
    expect(Theme.of(lightContext).brightness, Brightness.light);
    expect(lightContext.srColors, SrColors.light);
  });

  testWidgets('user and admin surfaces render with the dark design system', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final adminState = AppState();
    addTearDown(adminState.dispose);
    await adminState.applyBackendProfile(_profile(role: 'internal_admin'));
    await adminState.setThemePreference(SrThemePreference.dark);
    adminState.goTo(AppView.facilities);

    await tester.pumpWidget(_darkApp(adminState, const AppShell()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final view in const [
      AppView.reservations,
      AppView.verifications,
      AppView.calendar,
      AppView.users,
      AppView.reports,
      AppView.audit,
      AppView.profile,
    ]) {
      adminState.goTo(view);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull, reason: view.name);
    }

    final userState = AppState();
    addTearDown(userState.dispose);
    await userState.applyBackendProfile(_profile(role: 'user'));
    await userState.setThemePreference(SrThemePreference.dark);
    await tester.pumpWidget(_darkApp(userState, const StudentApp()));
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.byType(StudentApp))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'toggling the theme repaints the legacy SR-token app shell in a '
    'single frame',
    (tester) async {
      final state = AppState(useDemoData: false);
      addTearDown(state.dispose);

      await tester.pumpWidget(SmartReserveApp(state: state));
      await tester.pumpAndSettle();

      Color shellColor() =>
          tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;

      // Deliberately exercises the legacy SR.* path (the one with no
      // InheritedWidget behind it) rather than context.srColors, since
      // that path is exactly what SrThemeBridge exists to keep repainting.
      // ignore: deprecated_member_use_from_same_package
      expect(shellColor(), SR.bg);
      expect(shellColor(), isNot(SrColors.dark.canvas));

      await state.setThemePreference(SrThemePreference.dark);
      // Deliberately a single pump, not pumpAndSettle: the whole point of
      // the fix is that the switch lands in one frame instead of only
      // appearing after something else happens to rebuild the tree.
      await tester.pump();

      expect(shellColor(), SrColors.dark.canvas);

      await state.setThemePreference(SrThemePreference.light);
      await tester.pump();

      expect(shellColor(), SrColors.light.canvas);
    },
  );

  testWidgets(
    'a dialog opened over the app shell repaints in the same frame as '
    'the rest of the tree',
    (tester) async {
      final state = AppState(useDemoData: false);
      addTearDown(state.dispose);

      await tester.pumpWidget(SmartReserveApp(state: state));
      await tester.pumpAndSettle();

      final navigatorContext = tester.element(find.byType(Navigator).first);
      unawaited(
        showDialog<void>(
          context: navigatorContext,
          builder: (context) => Dialog(
            child: Builder(
              key: const Key('dialog-probe'),
              builder: (context) => ColoredBox(
                // ignore: deprecated_member_use_from_same_package
                color: SR.bg,
                child: const SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Color dialogColor() => tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byKey(const Key('dialog-probe')),
              matching: find.byType(ColoredBox),
            ),
          )
          .color;

      expect(dialogColor(), SrColors.light.canvas);

      await state.setThemePreference(SrThemePreference.dark);
      await tester.pump();

      expect(dialogColor(), SrColors.dark.canvas);
    },
  );

  testWidgets(
    'an OS-level brightness change reaches the app while on System',
    (tester) async {
      final state = AppState(useDemoData: false);
      addTearDown(state.dispose);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(SmartReserveApp(state: state));
      await tester.pumpAndSettle();

      expect(state.themePreference, SrThemePreference.system);

      Color shellColor() =>
          tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;

      expect(shellColor(), SrColors.light.canvas);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      // Unlike AppState.setThemePreference (whose notifyListeners() marks
      // the tree dirty before this test even calls pump()), a platform
      // brightness change is only observed once WidgetsBindingObserver
      // delivers didChangePlatformBrightness, which itself needs a frame.
      // The *second* pump is the one frame in which the change is actually
      // instant, matching the other two tests above.
      await tester.pump();
      await tester.pump();

      expect(shellColor(), SrColors.dark.canvas);
    },
  );
}

Widget _darkApp(AppState state, Widget home) => AppScope(
  state: state,
  child: MaterialApp(
    theme: SrThemeData.light(),
    darkTheme: SrThemeData.dark(),
    themeMode: ThemeMode.dark,
    builder: (context, child) => SrThemeBridge(child: child!),
    home: Scaffold(body: home),
  ),
);

SessionProfile _profile({required String role}) => SessionProfile(
  id: '$role-theme-test',
  email: '$role@csu.edu.ph',
  fullName: role == 'user' ? 'Theme Test Student' : 'Theme Test Administrator',
  role: role,
  campusClaim: role == 'user' ? 'student' : null,
  campusId: role == 'user' ? '2026-00123' : null,
  unit: role == 'user' ? 'BS Information Technology' : 'Registrar',
  verificationStatus: 'verified',
  onboardingComplete: true,
  accountStatus: 'active',
  createdAt: DateTime.utc(2026, 8, 22),
);

class _ThemeProbe extends StatelessWidget {
  const _ThemeProbe();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SizedBox(key: Key('theme-probe')));
}
