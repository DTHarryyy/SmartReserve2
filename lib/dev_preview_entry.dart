import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'app/app_view.dart';
import 'backend/supabase_service.dart';
import 'theme/sr_tokens.dart';
import 'widgets/toast_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
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

  @override
  Widget build(BuildContext context) => AppScope(
    state: state,
    child: MaterialApp(
      title: 'SmartReserve preview',
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
            borderRadius: BorderRadius.vertical(top: Radius.circular(SR.rXl)),
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
      home: const AppShell(),
    ),
  );
}
