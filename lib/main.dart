import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'backend/supabase_service.dart';
import 'theme/sr_tokens.dart';
import 'widgets/sr_logo.dart';
import 'widgets/toast_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('UNCAUGHT: $error\n$stack');
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
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _bootstrap,
    builder: (context, snapshot) => AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'SmartReserve · CSU Aparri',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'IBM Plex Sans',
          scaffoldBackgroundColor: SR.bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: SR.primary,
            primary: SR.primary,
            secondary: SR.primaryDeep,
            error: SR.red,
            surface: SR.surface,
          ),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          textSelectionTheme: const TextSelectionThemeData(
            selectionColor: SR.primaryLine,
            cursorColor: SR.primary,
            selectionHandleColor: SR.primary,
          ),
          tooltipTheme: TooltipThemeData(
            waitDuration: const Duration(milliseconds: 400),
            decoration: BoxDecoration(
              color: SR.ink,
              borderRadius: BorderRadius.circular(SR.rXs),
            ),
            textStyle: SrType.caption(color: SR.surface),
          ),
          scrollbarTheme: ScrollbarThemeData(
            thickness: WidgetStateProperty.all(10),
            thumbColor: WidgetStateProperty.all(SR.mutedLight),
            radius: const Radius.circular(SR.rXs),
          ),
          dividerTheme: const DividerThemeData(
            color: SR.border,
            thickness: 1,
            space: 1,
          ),
          appBarTheme: AppBarTheme(
            backgroundColor: SR.surface,
            foregroundColor: SR.ink,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            centerTitle: false,
            iconTheme: const IconThemeData(color: SR.ink2),
            titleTextStyle: SrType.heading(),
          ),
          iconButtonTheme: IconButtonThemeData(
            style: IconButton.styleFrom(
              foregroundColor: SR.ink2,
              disabledForegroundColor: SR.mutedLight,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: SR.primary,
              foregroundColor: SR.onDark,
              disabledBackgroundColor: SR.dividerSoft,
              disabledForegroundColor: SR.muted,
              elevation: 0,
              minimumSize: const Size(64, SR.controlLg),
              textStyle: SrType.button(color: SR.onDark),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SR.rSm),
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: SR.ink2,
              disabledForegroundColor: SR.muted,
              side: const BorderSide(color: SR.border),
              minimumSize: const Size(64, SR.controlLg),
              textStyle: SrType.button(),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SR.rSm),
              ),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: SR.primaryDeep,
              disabledForegroundColor: SR.muted,
              minimumSize: const Size(48, SR.controlMd),
              textStyle: SrType.button(color: SR.primaryDeep),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SR.rSm),
              ),
            ),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            backgroundColor: SR.primary,
            foregroundColor: SR.onDark,
            elevation: 2,
            focusElevation: 2,
            hoverElevation: 3,
            extendedTextStyle: SrType.button(color: SR.onDark),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SR.rMd),
            ),
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: SR.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SR.rLg),
            ),
            titleTextStyle: SrType.title(),
            contentTextStyle: SrType.body(),
          ),
          bottomSheetTheme: BottomSheetThemeData(
            backgroundColor: SR.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            modalBarrierColor: SR.scrim,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(SR.rXl),
              ),
            ),
          ),
          chipTheme: ChipThemeData(
            backgroundColor: SR.surfaceSubtle,
            side: const BorderSide(color: SR.border),
            labelStyle: SrType.bodySm(color: SR.ink2),
            padding: const EdgeInsets.symmetric(
              horizontal: SR.space8,
              vertical: SR.space4,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SR.rFull),
            ),
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: SR.surface,
            indicatorColor: SR.primaryTint,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            labelTextStyle: WidgetStateProperty.resolveWith(
              (states) => SrType.caption(
                w: 600,
                color: states.contains(WidgetState.selected)
                    ? SR.primaryDeep
                    : SR.ink4,
              ),
            ),
            iconTheme: WidgetStateProperty.resolveWith(
              (states) => IconThemeData(
                color: states.contains(WidgetState.selected)
                    ? SR.primary
                    : SR.ink4,
              ),
            ),
          ),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: SR.primary,
            linearTrackColor: SR.surfaceSunken,
            circularTrackColor: SR.surfaceSunken,
          ),
        ),
        builder: (context, child) =>
            AppToastHost(child: child ?? const SizedBox.shrink()),
        home: switch (snapshot.connectionState) {
          ConnectionState.waiting => Scaffold(
            backgroundColor: SR.bg,
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
          ),
          _ when snapshot.hasError => Scaffold(
            backgroundColor: SR.bg,
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
                        color: SR.redTint,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.wifi_off_rounded,
                        color: SR.red,
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
                    FilledButton(
                      onPressed: _retryBoot,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _ => const AppShell(),
        },
      ),
    ),
  );
}
