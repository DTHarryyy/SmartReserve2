import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'backend/push_service.dart';
import 'backend/supabase_service.dart';
import 'theme/sr_tokens.dart';
import 'theme/sr_theme.dart';
import 'model/notice.dart';
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
  // Push is only needed once a session exists, so Firebase starts after the
  // first frame instead of delaying it.
  unawaited(_configurePush(state));
}

// apiKey and appId are registered per-platform in Firebase (Project
// settings > Your apps); projectId and the sender id are shared across
// every app in the project. --dart-define overrides these for a different
// Firebase project without editing source.
const _firebaseApiKey = String.fromEnvironment(
  'FIREBASE_API_KEY',
  defaultValue: kIsWeb
      ? 'AIzaSyDTH-IQXefaw1hV6CFVTHMBbdjMXCKyzN4'
      : 'AIzaSyDedQ8K7CEHRPyQlDDMVpKZoHbyBVttHXQ',
);
const _firebaseAppId = String.fromEnvironment(
  'FIREBASE_APP_ID',
  defaultValue: kIsWeb
      ? '1:428216422364:web:d827a9e738cd91f01d8919'
      : '1:428216422364:android:c8ed36004b06cb7c1d8919',
);
const _firebaseMessagingSenderId = String.fromEnvironment(
  'FIREBASE_MESSAGING_SENDER_ID',
  defaultValue: '428216422364',
);
const _firebaseProjectId = String.fromEnvironment(
  'FIREBASE_PROJECT_ID',
  defaultValue: 'smartreserve-48784',
);
const _firebaseAuthDomain = String.fromEnvironment(
  'FIREBASE_AUTH_DOMAIN',
  defaultValue: 'smartreserve-48784.firebaseapp.com',
);

Future<void> _configurePush(AppState state) async {
  if (_firebaseApiKey.isEmpty ||
      _firebaseAppId.isEmpty ||
      _firebaseMessagingSenderId.isEmpty ||
      _firebaseProjectId.isEmpty) {
    return;
  }
  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: _firebaseApiKey,
        appId: _firebaseAppId,
        messagingSenderId: _firebaseMessagingSenderId,
        projectId: _firebaseProjectId,
        authDomain: _firebaseAuthDomain,
      ),
    );
    final push = PushService(
      registerToken: ({required token, required platform, deviceLabel}) =>
          state.backend!.registerPushToken(
            token: token,
            platform: platform,
            deviceLabel: deviceLabel,
          ),
      disableToken: (token) => state.backend!.disablePushToken(token),
      // The realtime channel already updates the bell; just surface it.
      onForegroundNotification: (title, body) {
        final text = [
          ?title,
          ?body,
        ].where((part) => part.trim().isNotEmpty).join(' — ');
        if (text.isNotEmpty) {
          state.showToast(ToastMessage(text, tone: AdvisoryTone.info));
        }
      },
      onNotificationOpened: state.handlePushNotificationOpened,
    );
    state.configurePush(push);
    unawaited(push.handleInitialMessage());
    // A restored session may have finished loading before Firebase was ready.
    if (state.hasSession) unawaited(push.registerIfAlreadyGranted());
  } catch (error) {
    debugPrint(
      'Firebase could not initialize; push notifications are disabled: $error',
    );
  }
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
  late ThemeMode _themeMode;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.state.themePreference.themeMode;
    widget.state.addListener(_syncThemeMode);
    _bootstrap = _boot();
  }

  @override
  void dispose() {
    widget.state.removeListener(_syncThemeMode);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(
      SrLogo.imageFor(
        _BootSplash.logoSize,
        MediaQuery.devicePixelRatioOf(context),
      ),
      context,
    );
  }

  // MaterialApp only rebuilds when the theme mode changes. Screens below
  // listen to AppState through AppScope, so rebuilding the whole app on every
  // state change is unnecessary.
  void _syncThemeMode() {
    final next = widget.state.themePreference.themeMode;
    if (next != _themeMode) setState(() => _themeMode = next);
  }

  Future<void> _boot() =>
      widget.state.initializeBackend().timeout(const Duration(seconds: 20));

  void _retryBoot() => setState(() => _bootstrap = _boot());

  @override
  Widget build(BuildContext context) => AppScope(
    state: widget.state,
    child: MaterialApp(
      title: 'SmartReserve · CSU Aparri',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: _themeMode,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
        child: SrThemeBridge(
          child: AppToastHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
      home: FutureBuilder<void>(
        future: _bootstrap,
        builder: (context, snapshot) => switch (snapshot.connectionState) {
          ConnectionState.waiting => const _BootSplash(),
          _ when snapshot.hasError => _BootError(
            error: snapshot.error!,
            onRetry: _retryBoot,
          ),
          _ => const AppShell(),
        },
      ),
    ),
  );
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  static const double logoSize = 80;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.srColors.canvas,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SrLogo(size: logoSize, radius: SR.rLg),
          const SizedBox(height: SR.space20),
          Text(
            'SmartReserve',
            style: SrType.title(color: context.srColors.ink),
          ),
          const SizedBox(height: SR.space32),
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ],
      ),
    ),
  );
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    final failure = classifyAuthFailure(error);
    final (icon, title, body) = switch (failure.kind) {
      AuthFailureKind.network => (
        Icons.wifi_off_rounded,
        'Could not connect',
        'Check your connection and try again.',
      ),
      AuthFailureKind.profileContractUnavailable => (
        Icons.cloud_sync_outlined,
        'SmartReserve is updating',
        'Account access is still being updated. Please try again shortly.',
      ),
      AuthFailureKind.profileAccessDenied => (
        Icons.lock_outline_rounded,
        'Account access unavailable',
        'This account cannot load its access profile. Contact an Internal Admin.',
      ),
      _ => (
        Icons.error_outline_rounded,
        'SmartReserve could not start',
        'Please try again. If this continues, contact an Internal Admin.',
      ),
    };
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
                child: Icon(icon, color: colors.error, size: 24),
              ),
              const SizedBox(height: SR.space16),
              Text(title, style: SrType.heading()),
              const SizedBox(height: SR.space6),
              Text(body, textAlign: TextAlign.center, style: SrType.bodySm()),
              const SizedBox(height: SR.space20),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
