import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'backend/supabase_service.dart';
import 'theme/sr_tokens.dart';
import 'theme/sr_theme.dart';
import 'widgets/sr_logo.dart';
import 'widgets/toast_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final errorSeenCount = <String, int>{};
  const maxFullPrints = 3;
  void logRateLimited(String key, void Function() printFull) {
    final seen = (errorSeenCount[key] ?? 0) + 1;
    errorSeenCount[key] = seen;
    if (seen <= maxFullPrints) {
      printFull();
    } else if (seen == maxFullPrints + 1 || seen % 200 == 0) {
      debugPrint('(suppressing further "$key" errors — $seen seen so far)');
    }
  }

  FlutterError.onError = (details) {
    logRateLimited(
      details.exception.toString(),
      () => FlutterError.presentError(details),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logRateLimited('$error', () => debugPrint('UNCAUGHT: $error\n$stack'));
    return true;
  };
  final state = AppState(useDemoData: false);
  const url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://tyniwgrvfxkfzhbiufib.supabase.co',
  );
  const key = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_8TRsZIH1OEeEGkOrJ0y7oQ_g_IRxcr8',
  );
  await Supabase.initialize(url: url, publishableKey: key);
  state.configureBackend(SupabaseService(Supabase.instance.client));
  runApp(SmartReserveApp(state: state));
}

class SmartReserveApp extends StatefulWidget {
  const SmartReserveApp({super.key, required this.state});

  final AppState state;

  @override
  State<SmartReserveApp> createState() => _SmartReserveAppState();
}

class _SmartReserveAppState extends State<SmartReserveApp> {
  static final _lightTheme = SrThemeData.light();
  static final _darkTheme = SrThemeData.dark();

  late Future<void> _bootstrap;

  @override
  void initState() {
    super.initState();
    _bootstrap = _boot();
  }

  Future<void> _boot() =>
      widget.state.initializeBackend().timeout(const Duration(seconds: 20));

  void _retryBoot() => setState(() => _bootstrap = _boot());

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) => FutureBuilder<void>(
      future: _bootstrap,
      builder: (context, snapshot) => AppScope(
        state: widget.state,
        child: MaterialApp(
          title: 'SmartReserve · CSU Aparri',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: widget.state.themePreference.themeMode,
          themeAnimationDuration: Duration.zero,
          builder: (context, child) => SrThemeBridge(
            child: AppToastHost(child: child ?? const SizedBox.shrink()),
          ),
          home: switch (snapshot.connectionState) {
            ConnectionState.waiting => const _BootSplash(),
            _ when snapshot.hasError => _BootError(onRetry: _retryBoot),
            _ => const AppShell(),
          },
        ),
      ),
    ),
  );
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.srColors.canvas,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SrLogo(size: 44, radius: SR.rMd),
          const SizedBox(height: SR.space24),
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ],
      ),
    ),
  );
}

class _BootError extends StatelessWidget {
  const _BootError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(SR.space24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.wifi_off_rounded,
                  color: colors.error,
                  size: 24,
                ),
              ),
              const SizedBox(height: SR.space16),
              Text('Could not connect', style: SrType.heading()),
              const SizedBox(height: SR.space6),
              Text(
                'Check your connection and try again.',
                textAlign: TextAlign.center,
                style: SrType.bodySm(),
              ),
              const SizedBox(height: SR.space20),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
