import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'app/app_view.dart';
import 'backend/supabase_service.dart';
import 'theme/sr_theme.dart';
import 'widgets/toast_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.loadThemePreference();
  await state.applyBackendProfile(
    const SessionProfile(
      id: 'preview-admin',
      email: 'admin@csu.edu.ph',
      fullName: 'Dana Herrera',
      role: 'internal_admin',
      campusClaim: null,
      campusId: null,
      unit: 'Office of the Registrar',
      verificationStatus: 'verified',
      onboardingComplete: true,
      accountStatus: 'active',
      createdAt: null,
    ),
  );
  state.goTo(AppView.facilities);
  runApp(_PreviewApp(state: state));
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp({required this.state});

  final AppState state;

  static final _lightTheme = SrThemeData.light();
  static final _darkTheme = SrThemeData.dark();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => AppScope(
      state: state,
      child: MaterialApp(
        title: 'SmartReserve preview',
        debugShowCheckedModeBanner: false,
        theme: _lightTheme,
        darkTheme: _darkTheme,
        themeMode: state.themePreference.themeMode,
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => SrThemeBridge(
          child: AppToastHost(child: child ?? const SizedBox.shrink()),
        ),
        home: const AppShell(),
      ),
    ),
  );
}
