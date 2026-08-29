import 'package:flutter/material.dart';

import 'sr_tokens.dart';

enum SrThemePreference {
  system('System'),
  light('Light'),
  dark('Dark');

  const SrThemePreference(this.label);

  final String label;

  ThemeMode get themeMode => switch (this) {
    SrThemePreference.system => ThemeMode.system,
    SrThemePreference.light => ThemeMode.light,
    SrThemePreference.dark => ThemeMode.dark,
  };

  static SrThemePreference fromStorage(String? value) => switch (value) {
    'light' => SrThemePreference.light,
    'dark' => SrThemePreference.dark,
    _ => SrThemePreference.system,
  };
}

@immutable
class SrColors extends ThemeExtension<SrColors> {
  const SrColors({
    required this.brand,
    required this.secondary,
    required this.accent,
    required this.canvas,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceSubtle,
    required this.surfaceSunken,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.borderStrong,
    required this.focus,
    required this.overlay,
    required this.success,
    required this.successContainer,
    required this.warning,
    required this.warningContainer,
    required this.error,
    required this.errorContainer,
    required this.info,
    required this.infoContainer,
    required this.primarySoft,
    required this.primaryLine,
    required this.primaryTint2,
    required this.mapBg,
    required this.navAvatar,
    required this.navBorder,
    required this.borderField,
    required this.hairline,
    required this.divider,
    required this.dividerSoft,
    required this.dashed,
    required this.ink2,
    required this.muted,
    required this.mutedLight,
    required this.scrimSoft,
    required this.glass,
    required this.glassLine,
    required this.glassLine2,
    required this.greenDeep,
    required this.greenTint2,
    required this.greenLine,
    required this.amber,
    required this.amberLine,
    required this.amberLine2,
    required this.amberIcon,
    required this.amberInk,
    required this.amberTitle,
    required this.redLine,
    required this.redInk,
    required this.redInk2,
    required this.isDark,
    required this.cardShadow,
    required this.floatShadow,
    required this.popoverShadow,
    required this.dialogShadow,
  });

  static const light = SrColors(
    brand: Color(0xFF1A73E8),
    secondary: Color(0xFF00B4FF),
    accent: Color(0xFF00E0C7),
    canvas: Color(0xFFF5F7FA),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFFAFCFF),
    surfaceSunken: Color(0xFFEDF2F7),
    text: Color(0xFF0B1B33),
    textSecondary: Color(0xFF40556C),
    textMuted: Color(0xFF60748A),
    border: Color(0xFFE2EAF2),
    borderStrong: Color(0xFFB8C6D5),
    focus: Color(0xFF1A73E8),
    overlay: Color(0x700B1B33),
    success: Color(0xFF0F7A4D),
    successContainer: Color(0xFFECFDF3),
    warning: Color(0xFF9A4A08),
    warningContainer: Color(0xFFFFFBF2),
    error: Color(0xFFB42318),
    errorContainer: Color(0xFFFEF3F2),
    info: Color(0xFF155DB8),
    infoContainer: Color(0xFFEAF3FF),
    primarySoft: Color(0xFF78AFF1),
    primaryLine: Color(0xFFBDD9FA),
    primaryTint2: Color(0xFFF4F9FF),
    mapBg: Color(0xFFE8EEF5),
    navAvatar: Color(0xFFEAF3FF),
    navBorder: Color(0xFFE4EBF3),
    borderField: Color(0xFFD8E2EC),
    hairline: Color(0xFFEDF2F7),
    divider: Color(0xFFEAF0F6),
    dividerSoft: Color(0xFFF0F4F8),
    dashed: Color(0xFFC5D1DD),
    ink2: Color(0xFF263A52),
    muted: Color(0xFF8798AA),
    mutedLight: Color(0xFFB6C2CE),
    scrimSoft: Color(0x5C0B1B33),
    glass: Color(0xF7FFFFFF),
    glassLine: Color(0x140B1B33),
    glassLine2: Color(0x1F0B1B33),
    greenDeep: Color(0xFF0A5C3A),
    greenTint2: Color(0xFFF2FDF7),
    greenLine: Color(0xFFB7E9CD),
    amber: Color(0xFFB45309),
    amberLine: Color(0xFFF0D9A8),
    amberLine2: Color(0xFFE6D5B4),
    amberIcon: Color(0xFFFDF0D5),
    amberInk: Color(0xFF8A6535),
    amberTitle: Color(0xFF7A4A09),
    redLine: Color(0xFFF2C4C0),
    redInk: Color(0xFF912018),
    redInk2: Color(0xFFA4413A),
    isDark: false,
    cardShadow: [
      BoxShadow(color: Color(0x100B1B33), blurRadius: 8, offset: Offset(0, 2)),
    ],
    floatShadow: [
      BoxShadow(color: Color(0x1A0B1B33), blurRadius: 18, offset: Offset(0, 5)),
    ],
    popoverShadow: [
      BoxShadow(
        color: Color(0x290B1B33),
        blurRadius: 34,
        offset: Offset(0, 16),
      ),
    ],
    dialogShadow: [
      BoxShadow(
        color: Color(0x520B1B33),
        blurRadius: 70,
        offset: Offset(0, 30),
      ),
    ],
  );

  static const dark = SrColors(
    brand: Color(0xFF68AEFA),
    secondary: Color(0xFF43C5FF),
    accent: Color(0xFF42E8D4),
    canvas: Color(0xFF071321),
    surface: Color(0xFF0B1B33),
    surfaceElevated: Color(0xFF10243D),
    surfaceSubtle: Color(0xFF10243D),
    surfaceSunken: Color(0xFF06101D),
    text: Color(0xFFF7FAFE),
    textSecondary: Color(0xFFBED0E3),
    textMuted: Color(0xFF91A9C0),
    border: Color(0xFF203A57),
    borderStrong: Color(0xFF3C6489),
    focus: Color(0xFF68AEFA),
    overlay: Color(0xB8050D17),
    success: Color(0xFF5FE2A6),
    successContainer: Color(0xFF0C3529),
    warning: Color(0xFFFFC65C),
    warningContainer: Color(0xFF3A2A10),
    error: Color(0xFFFF8078),
    errorContainer: Color(0xFF3D1C20),
    info: Color(0xFF8BC4FF),
    infoContainer: Color(0xFF102F54),
    primarySoft: Color(0xFF4A85BE),
    primaryLine: Color(0xFF24588E),
    primaryTint2: Color(0xFF0E2846),
    mapBg: Color(0xFF0A1728),
    navAvatar: Color(0xFF15345A),
    navBorder: Color(0xFF1D3653),
    borderField: Color(0xFF294866),
    hairline: Color(0xFF172F49),
    divider: Color(0xFF17304A),
    dividerSoft: Color(0xFF132A42),
    dashed: Color(0xFF3A5875),
    ink2: Color(0xFFDDE8F5),
    muted: Color(0xFF7690A9),
    mutedLight: Color(0xFF526D88),
    scrimSoft: Color(0x99050D17),
    glass: Color(0xF20B1B33),
    glassLine: Color(0x264C6D8E),
    glassLine2: Color(0x3D5E7E9D),
    greenDeep: Color(0xFF8AEABD),
    greenTint2: Color(0xFF0A2B22),
    greenLine: Color(0xFF176348),
    amber: Color(0xFFFFC65C),
    amberLine: Color(0xFF6A4B17),
    amberLine2: Color(0xFF725825),
    amberIcon: Color(0xFF513812),
    amberInk: Color(0xFFF3CC83),
    amberTitle: Color(0xFFFFD483),
    redLine: Color(0xFF753039),
    redInk: Color(0xFFFFA29C),
    redInk2: Color(0xFFFFB3AE),
    isDark: true,
    cardShadow: [],
    floatShadow: [
      BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6)),
    ],
    popoverShadow: [
      BoxShadow(
        color: Color(0x8A000000),
        blurRadius: 34,
        offset: Offset(0, 16),
      ),
    ],
    dialogShadow: [
      BoxShadow(
        color: Color(0xB3000000),
        blurRadius: 70,
        offset: Offset(0, 30),
      ),
    ],
  );

  final Color brand;
  final Color secondary;
  final Color accent;
  final Color canvas;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceSubtle;
  final Color surfaceSunken;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color border;
  final Color borderStrong;
  final Color focus;
  final Color overlay;
  final Color success;
  final Color successContainer;
  final Color warning;
  final Color warningContainer;
  final Color error;
  final Color errorContainer;
  final Color info;
  final Color infoContainer;
  final Color primarySoft;
  final Color primaryLine;
  final Color primaryTint2;
  final Color mapBg;
  final Color navAvatar;
  final Color navBorder;
  final Color borderField;
  final Color hairline;
  final Color divider;
  final Color dividerSoft;
  final Color dashed;
  final Color ink2;
  final Color muted;
  final Color mutedLight;
  final Color scrimSoft;
  final Color glass;
  final Color glassLine;
  final Color glassLine2;
  final Color greenDeep;
  final Color greenTint2;
  final Color greenLine;
  final Color amber;
  final Color amberLine;
  final Color amberLine2;
  final Color amberIcon;
  final Color amberInk;
  final Color amberTitle;
  final Color redLine;
  final Color redInk;
  final Color redInk2;
  final bool isDark;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> floatShadow;
  final List<BoxShadow> popoverShadow;
  final List<BoxShadow> dialogShadow;

  // --- Aliases -------------------------------------------------------
  // Same value as an existing canonical field above, kept under the name
  // the legacy SR.* getter used, so Stage 4 call-site rewrites can pick
  // whichever reads best without introducing a second source of truth.
  Color get bg => canvas;
  Color get navBg => surface;
  Color get navAvatarFg => info;
  Color get ink => text;
  Color get ink3 => textSecondary;
  Color get ink4 => textMuted;
  Color get scrim => overlay;
  Color get greenDark => success;
  Color get greenTint => successContainer;
  Color get amberTint => warningContainer;
  Color get red => error;
  Color get redTint => errorContainer;
  Color get primaryDeep => info;
  Color get primaryTint => infoContainer;
  Color get borderHover => borderStrong;
  List<BoxShadow> get toastShadow => popoverShadow;

  @override
  SrColors copyWith({
    Color? brand,
    Color? secondary,
    Color? accent,
    Color? canvas,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceSubtle,
    Color? surfaceSunken,
    Color? text,
    Color? textSecondary,
    Color? textMuted,
    Color? border,
    Color? borderStrong,
    Color? focus,
    Color? overlay,
    Color? success,
    Color? successContainer,
    Color? warning,
    Color? warningContainer,
    Color? error,
    Color? errorContainer,
    Color? info,
    Color? infoContainer,
    Color? primarySoft,
    Color? primaryLine,
    Color? primaryTint2,
    Color? mapBg,
    Color? navAvatar,
    Color? navBorder,
    Color? borderField,
    Color? hairline,
    Color? divider,
    Color? dividerSoft,
    Color? dashed,
    Color? ink2,
    Color? muted,
    Color? mutedLight,
    Color? scrimSoft,
    Color? glass,
    Color? glassLine,
    Color? glassLine2,
    Color? greenDeep,
    Color? greenTint2,
    Color? greenLine,
    Color? amber,
    Color? amberLine,
    Color? amberLine2,
    Color? amberIcon,
    Color? amberInk,
    Color? amberTitle,
    Color? redLine,
    Color? redInk,
    Color? redInk2,
    bool? isDark,
    List<BoxShadow>? cardShadow,
    List<BoxShadow>? floatShadow,
    List<BoxShadow>? popoverShadow,
    List<BoxShadow>? dialogShadow,
  }) => SrColors(
    brand: brand ?? this.brand,
    secondary: secondary ?? this.secondary,
    accent: accent ?? this.accent,
    canvas: canvas ?? this.canvas,
    surface: surface ?? this.surface,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    surfaceSubtle: surfaceSubtle ?? this.surfaceSubtle,
    surfaceSunken: surfaceSunken ?? this.surfaceSunken,
    text: text ?? this.text,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    focus: focus ?? this.focus,
    overlay: overlay ?? this.overlay,
    success: success ?? this.success,
    successContainer: successContainer ?? this.successContainer,
    warning: warning ?? this.warning,
    warningContainer: warningContainer ?? this.warningContainer,
    error: error ?? this.error,
    errorContainer: errorContainer ?? this.errorContainer,
    info: info ?? this.info,
    infoContainer: infoContainer ?? this.infoContainer,
    primarySoft: primarySoft ?? this.primarySoft,
    primaryLine: primaryLine ?? this.primaryLine,
    primaryTint2: primaryTint2 ?? this.primaryTint2,
    mapBg: mapBg ?? this.mapBg,
    navAvatar: navAvatar ?? this.navAvatar,
    navBorder: navBorder ?? this.navBorder,
    borderField: borderField ?? this.borderField,
    hairline: hairline ?? this.hairline,
    divider: divider ?? this.divider,
    dividerSoft: dividerSoft ?? this.dividerSoft,
    dashed: dashed ?? this.dashed,
    ink2: ink2 ?? this.ink2,
    muted: muted ?? this.muted,
    mutedLight: mutedLight ?? this.mutedLight,
    scrimSoft: scrimSoft ?? this.scrimSoft,
    glass: glass ?? this.glass,
    glassLine: glassLine ?? this.glassLine,
    glassLine2: glassLine2 ?? this.glassLine2,
    greenDeep: greenDeep ?? this.greenDeep,
    greenTint2: greenTint2 ?? this.greenTint2,
    greenLine: greenLine ?? this.greenLine,
    amber: amber ?? this.amber,
    amberLine: amberLine ?? this.amberLine,
    amberLine2: amberLine2 ?? this.amberLine2,
    amberIcon: amberIcon ?? this.amberIcon,
    amberInk: amberInk ?? this.amberInk,
    amberTitle: amberTitle ?? this.amberTitle,
    redLine: redLine ?? this.redLine,
    redInk: redInk ?? this.redInk,
    redInk2: redInk2 ?? this.redInk2,
    isDark: isDark ?? this.isDark,
    cardShadow: cardShadow ?? this.cardShadow,
    floatShadow: floatShadow ?? this.floatShadow,
    popoverShadow: popoverShadow ?? this.popoverShadow,
    dialogShadow: dialogShadow ?? this.dialogShadow,
  );

  @override
  SrColors lerp(covariant SrColors? other, double t) {
    if (other == null) return this;
    Color blend(Color a, Color b) => Color.lerp(a, b, t)!;
    return SrColors(
      brand: blend(brand, other.brand),
      secondary: blend(secondary, other.secondary),
      accent: blend(accent, other.accent),
      canvas: blend(canvas, other.canvas),
      surface: blend(surface, other.surface),
      surfaceElevated: blend(surfaceElevated, other.surfaceElevated),
      surfaceSubtle: blend(surfaceSubtle, other.surfaceSubtle),
      surfaceSunken: blend(surfaceSunken, other.surfaceSunken),
      text: blend(text, other.text),
      textSecondary: blend(textSecondary, other.textSecondary),
      textMuted: blend(textMuted, other.textMuted),
      border: blend(border, other.border),
      borderStrong: blend(borderStrong, other.borderStrong),
      focus: blend(focus, other.focus),
      overlay: blend(overlay, other.overlay),
      success: blend(success, other.success),
      successContainer: blend(successContainer, other.successContainer),
      warning: blend(warning, other.warning),
      warningContainer: blend(warningContainer, other.warningContainer),
      error: blend(error, other.error),
      errorContainer: blend(errorContainer, other.errorContainer),
      info: blend(info, other.info),
      infoContainer: blend(infoContainer, other.infoContainer),
      primarySoft: blend(primarySoft, other.primarySoft),
      primaryLine: blend(primaryLine, other.primaryLine),
      primaryTint2: blend(primaryTint2, other.primaryTint2),
      mapBg: blend(mapBg, other.mapBg),
      navAvatar: blend(navAvatar, other.navAvatar),
      navBorder: blend(navBorder, other.navBorder),
      borderField: blend(borderField, other.borderField),
      hairline: blend(hairline, other.hairline),
      divider: blend(divider, other.divider),
      dividerSoft: blend(dividerSoft, other.dividerSoft),
      dashed: blend(dashed, other.dashed),
      ink2: blend(ink2, other.ink2),
      muted: blend(muted, other.muted),
      mutedLight: blend(mutedLight, other.mutedLight),
      scrimSoft: blend(scrimSoft, other.scrimSoft),
      glass: blend(glass, other.glass),
      glassLine: blend(glassLine, other.glassLine),
      glassLine2: blend(glassLine2, other.glassLine2),
      greenDeep: blend(greenDeep, other.greenDeep),
      greenTint2: blend(greenTint2, other.greenTint2),
      greenLine: blend(greenLine, other.greenLine),
      amber: blend(amber, other.amber),
      amberLine: blend(amberLine, other.amberLine),
      amberLine2: blend(amberLine2, other.amberLine2),
      amberIcon: blend(amberIcon, other.amberIcon),
      amberInk: blend(amberInk, other.amberInk),
      amberTitle: blend(amberTitle, other.amberTitle),
      redLine: blend(redLine, other.redLine),
      redInk: blend(redInk, other.redInk),
      redInk2: blend(redInk2, other.redInk2),
      // Bool/shadow-list fields have no meaningful interpolation; snap at
      // the midpoint like ThemeData.lerp does for `brightness` itself.
      isDark: t < 0.5 ? isDark : other.isDark,
      cardShadow: t < 0.5 ? cardShadow : other.cardShadow,
      floatShadow: t < 0.5 ? floatShadow : other.floatShadow,
      popoverShadow: t < 0.5 ? popoverShadow : other.popoverShadow,
      dialogShadow: t < 0.5 ? dialogShadow : other.dialogShadow,
    );
  }
}

extension SrThemeContext on BuildContext {
  SrColors get srColors =>
      Theme.of(this).extension<SrColors>() ??
      (Theme.of(this).brightness == Brightness.dark
          ? SrColors.dark
          : SrColors.light);
}

abstract final class SrThemeData {
  static ThemeData light() => _build(Brightness.light, SrColors.light);

  static ThemeData dark() => _build(Brightness.dark, SrColors.dark);

  static ThemeData _build(Brightness brightness, SrColors colors) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      brightness: brightness,
      seedColor: const Color(0xFF1A73E8),
      primary: dark ? const Color(0xFF68AEFA) : const Color(0xFF1A73E8),
      secondary: dark ? const Color(0xFF43C5FF) : const Color(0xFF00B4FF),
      tertiary: dark ? const Color(0xFF42E8D4) : const Color(0xFF00AFA0),
      error: colors.error,
      surface: colors.surface,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Poppins',
      scaffoldBackgroundColor: colors.canvas,
      colorScheme: scheme,
      extensions: [colors],
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: colors.textSecondary,
        displayColor: colors.text,
        fontFamily: 'Poppins',
      ),
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: colors.brand.withValues(alpha: .28),
        cursorColor: colors.brand,
        selectionHandleColor: colors.brand,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFEAF3FF) : const Color(0xFF0B1B33),
          borderRadius: BorderRadius.circular(SR.rSm),
        ),
        textStyle: SrType.caption(
          color: dark ? const Color(0xFF0B1B33) : Colors.white,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        thumbColor: WidgetStatePropertyAll(
          colors.textMuted.withValues(alpha: .6),
        ),
        radius: const Radius.circular(SR.rFull),
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        iconTheme: IconThemeData(color: colors.textSecondary),
        titleTextStyle: SrType.heading(color: colors.text),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colors.textSecondary,
          disabledForegroundColor: colors.textMuted.withValues(alpha: .55),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1A73E8),
          foregroundColor: Colors.white,
          disabledBackgroundColor: colors.surfaceSunken,
          disabledForegroundColor: colors.textMuted,
          elevation: 0,
          minimumSize: const Size(64, SR.controlLg),
          textStyle: SrType.button(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SR.rSm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.textSecondary,
          disabledForegroundColor: colors.textMuted,
          side: BorderSide(color: colors.border),
          minimumSize: const Size(64, SR.controlLg),
          textStyle: SrType.button(color: colors.textSecondary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SR.rSm),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.info,
          disabledForegroundColor: colors.textMuted,
          minimumSize: const Size(48, SR.controlMd),
          textStyle: SrType.button(color: colors.info),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SR.rSm),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: const Color(0xFF1A73E8),
        foregroundColor: Colors.white,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        extendedTextStyle: SrType.button(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SR.rLg),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: dark ? 0 : 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SR.rXl),
        ),
        titleTextStyle: SrType.title(color: colors.text),
        contentTextStyle: SrType.body(color: colors.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBarrierColor: colors.overlay,
        showDragHandle: true,
        dragHandleColor: colors.borderStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(SR.rXl)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colors.surfaceSubtle,
        side: BorderSide(color: colors.border),
        labelStyle: SrType.bodySm(color: colors.textSecondary),
        padding: const EdgeInsets.symmetric(
          horizontal: SR.space8,
          vertical: SR.space4,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SR.rFull),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        indicatorColor: colors.infoContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => SrType.caption(
            w: 600,
            color: states.contains(WidgetState.selected)
                ? colors.info
                : colors.textMuted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.brand
                : colors.textMuted,
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: const Color(0xFF00B4FF),
        linearTrackColor: colors.surfaceSunken,
        circularTrackColor: colors.surfaceSunken,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surface,
        hintStyle: SrType.body(color: colors.textMuted),
        labelStyle: SrType.label(color: colors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SR.rMd),
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SR.rMd),
          borderSide: BorderSide(color: colors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SR.rMd),
          borderSide: BorderSide(color: colors.focus, width: 1.5),
        ),
      ),
    );
  }
}

/// Bridges the reactive [ThemeData] the app now resolves ([MaterialApp]'s
/// `theme`/`darkTheme`/`themeMode`) with the legacy static [SR] token API
/// that most screens still read directly. `SR.*` getters are plain static
/// fields with no [InheritedWidget] behind them, so flipping them alone does
/// not mark any descendant dirty — widgets only repaint if something else
/// happens to rebuild them.
///
/// This widget keeps [SR] in sync on every build *and*, when the resolved
/// [Brightness] actually changes, force-rebuilds the entire subtree below it
/// (including whatever the root [Navigator]/[Overlay] is currently showing,
/// so open dialogs and bottom sheets repaint too) on the next frame.
///
/// Migration note: delete this bridge once every `SR.*` colour read has been
/// migrated to `context.srColors` (see the theming implementation plan,
/// Stage 7). At that point every colour will be resolved from [BuildContext]
/// directly and Flutter's normal dependency tracking is enough on its own.
class SrThemeBridge extends StatefulWidget {
  const SrThemeBridge({super.key, required this.child});

  final Widget child;

  @override
  State<SrThemeBridge> createState() => _SrThemeBridgeState();
}

class _SrThemeBridgeState extends State<SrThemeBridge> {
  Brightness? _lastBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    SR.activate(brightness);
    if (_lastBrightness != null && _lastBrightness != brightness) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.visitChildElements(_forceRebuild);
      });
    }
    _lastBrightness = brightness;
  }

  static void _forceRebuild(Element element) {
    element.markNeedsBuild();
    element.visitChildren(_forceRebuild);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SrThemeSelector extends StatelessWidget {
  const SrThemeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final SrThemePreference value;
  final ValueChanged<SrThemePreference> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) => SegmentedButton<SrThemePreference>(
    showSelectedIcon: false,
    segments: [
      for (final preference in SrThemePreference.values)
        ButtonSegment(
          value: preference,
          icon: Icon(switch (preference) {
            SrThemePreference.system => Icons.brightness_auto_rounded,
            SrThemePreference.light => Icons.light_mode_rounded,
            SrThemePreference.dark => Icons.dark_mode_rounded,
          }, size: 17),
          label: compact ? null : Text(preference.label),
          tooltip: '${preference.label} appearance',
        ),
    ],
    selected: {value},
    onSelectionChanged: (selection) => onChanged(selection.first),
  );
}
