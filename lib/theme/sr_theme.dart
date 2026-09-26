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
    required this.brandHover,
    required this.brandPressed,
    required this.onBrand,
    required this.secondary,
    required this.accent,
    required this.onAccent,
    required this.brandContainer,
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
    required this.infoLine,
    required this.primarySoft,
    required this.primaryLine,
    required this.primaryTint2,
    required this.mapBg,
    required this.navBg,
    required this.navForeground,
    required this.navMuted,
    required this.navHover,
    required this.navSelectedBg,
    required this.navSelectedForeground,
    required this.navAvatar,
    required this.navBorder,
    required this.heroStart,
    required this.heroEnd,
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
    brand: Color(0xFF800020),
    brandHover: Color(0xFF6B001B),
    brandPressed: Color(0xFF520015),
    onBrand: Color(0xFFFFFFFF),
    secondary: Color(0xFFFFC857),
    accent: Color(0xFFFFC857),
    onAccent: Color(0xFF3A2100),
    brandContainer: Color(0xFFF7E7EB),
    canvas: Color(0xFFF3EFF5),
    surface: Color(0xFFFFFBFC),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFF8F3F6),
    surfaceSunken: Color(0xFFE9E0E5),
    text: Color(0xFF2B151D),
    textSecondary: Color(0xFF5F4650),
    textMuted: Color(0xFF7C626D),
    border: Color(0xFFDECED5),
    borderStrong: Color(0xFFBFA7B1),
    focus: Color(0xFF800020),
    overlay: Color(0x802B151D),
    success: Color(0xFF246B3D),
    successContainer: Color(0xFFEDF7F0),
    warning: Color(0xFF754B00),
    warningContainer: Color(0xFFFFF4D6),
    error: Color(0xFFA61B35),
    errorContainer: Color(0xFFFDECEF),
    info: Color(0xFF4D5F91),
    infoContainer: Color(0xFFEEF1FA),
    infoLine: Color(0xFFC8CEE7),
    primarySoft: Color(0xFFE7A8B8),
    primaryLine: Color(0xFFD8AAB6),
    primaryTint2: Color(0xFFFCF6F8),
    mapBg: Color(0xFFEBE2E7),
    navBg: Color(0xFFFFFFFF),
    navForeground: Color(0xFF2B151D),
    navMuted: Color(0xFF7C626D),
    navHover: Color(0xFFF7E7EB),
    navSelectedBg: Color(0xFFFFC857),
    navSelectedForeground: Color(0xFF3A2100),
    navAvatar: Color(0xFFFFC857),
    navBorder: Color(0xFFDECED5),
    heroStart: Color(0xFF800020),
    heroEnd: Color(0xFF5A0017),
    borderField: Color(0xFFD4C1CA),
    hairline: Color(0xFFEDE4E8),
    divider: Color(0xFFE8DBE1),
    dividerSoft: Color(0xFFF0E8EC),
    dashed: Color(0xFFC9B4BD),
    ink2: Color(0xFF442B35),
    muted: Color(0xFF927783),
    mutedLight: Color(0xFFB9A3AC),
    scrimSoft: Color(0x662B151D),
    glass: Color(0xF7FFFBFC),
    glassLine: Color(0x18800020),
    glassLine2: Color(0x28800020),
    greenDeep: Color(0xFF1D5A33),
    greenTint2: Color(0xFFF4FBF6),
    greenLine: Color(0xFFB8DEC5),
    amber: Color(0xFF754B00),
    amberLine: Color(0xFFE6C46C),
    amberLine2: Color(0xFFD6AF4D),
    amberIcon: Color(0xFFFFE8A8),
    amberInk: Color(0xFF754B00),
    amberTitle: Color(0xFF754B00),
    redLine: Color(0xFFEBB5C0),
    redInk: Color(0xFF8B142B),
    redInk2: Color(0xFF96182F),
    isDark: false,
    cardShadow: [
      BoxShadow(color: Color(0x142B151D), blurRadius: 8, offset: Offset(0, 2)),
    ],
    floatShadow: [
      BoxShadow(color: Color(0x242B151D), blurRadius: 18, offset: Offset(0, 5)),
    ],
    popoverShadow: [
      BoxShadow(
        color: Color(0x382B151D),
        blurRadius: 34,
        offset: Offset(0, 16),
      ),
    ],
    dialogShadow: [
      BoxShadow(
        color: Color(0x662B151D),
        blurRadius: 70,
        offset: Offset(0, 30),
      ),
    ],
  );

  static const dark = SrColors(
    brand: Color(0xFFFFC857),
    brandHover: Color(0xFFFFD77F),
    brandPressed: Color(0xFFE8AF37),
    onBrand: Color(0xFF3A2100),
    secondary: Color(0xFFFFADC0),
    accent: Color(0xFFFFC857),
    onAccent: Color(0xFF3A2100),
    brandContainer: Color(0xFF3B2A08),
    canvas: Color(0xFF160B10),
    surface: Color(0xFF241219),
    surfaceElevated: Color(0xFF301820),
    surfaceSubtle: Color(0xFF2A151D),
    surfaceSunken: Color(0xFF10070B),
    text: Color(0xFFF8EEF2),
    textSecondary: Color(0xFFDFC8D1),
    textMuted: Color(0xFFB2929F),
    border: Color(0xFF4B2A36),
    borderStrong: Color(0xFF785160),
    focus: Color(0xFFFFC857),
    overlay: Color(0xC0080305),
    success: Color(0xFF79D99A),
    successContainer: Color(0xFF183222),
    warning: Color(0xFFFFC857),
    warningContainer: Color(0xFF3B2A08),
    error: Color(0xFFFF95A8),
    errorContainer: Color(0xFF481722),
    info: Color(0xFFAEB8E8),
    infoContainer: Color(0xFF252A49),
    infoLine: Color(0xFF505982),
    primarySoft: Color(0xFFFFE39C),
    primaryLine: Color(0xFF76591D),
    primaryTint2: Color(0xFF302207),
    mapBg: Color(0xFF1E1015),
    navBg: Color(0xFF241219),
    navForeground: Color(0xFFF8EEF2),
    navMuted: Color(0xFFB2929F),
    navHover: Color(0xFF2A151D),
    navSelectedBg: Color(0xFFFFC857),
    navSelectedForeground: Color(0xFF3A2100),
    navAvatar: Color(0xFFFFC857),
    navBorder: Color(0xFF4B2A36),
    heroStart: Color(0xFF800020),
    heroEnd: Color(0xFF3B000F),
    borderField: Color(0xFF593542),
    hairline: Color(0xFF351E27),
    divider: Color(0xFF3D222C),
    dividerSoft: Color(0xFF321A23),
    dashed: Color(0xFF6D4855),
    ink2: Color(0xFFEDDCE3),
    muted: Color(0xFF9B7A87),
    mutedLight: Color(0xFF765461),
    scrimSoft: Color(0xA6080305),
    glass: Color(0xF2241219),
    glassLine: Color(0x3DFFE0E8),
    glassLine2: Color(0x52FFE0E8),
    greenDeep: Color(0xFFA4E9BA),
    greenTint2: Color(0xFF12291C),
    greenLine: Color(0xFF356847),
    amber: Color(0xFFFFC857),
    amberLine: Color(0xFF76591D),
    amberLine2: Color(0xFF8A6A25),
    amberIcon: Color(0xFF503908),
    amberInk: Color(0xFFFFE39C),
    amberTitle: Color(0xFFFFE39C),
    redLine: Color(0xFF783144),
    redInk: Color(0xFFFFC0CC),
    redInk2: Color(0xFFFFAFC0),
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
  final Color brandHover;
  final Color brandPressed;
  final Color onBrand;
  final Color secondary;
  final Color accent;
  final Color onAccent;
  final Color brandContainer;
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
  final Color infoLine;
  final Color primarySoft;
  final Color primaryLine;
  final Color primaryTint2;
  final Color mapBg;
  final Color navBg;
  final Color navForeground;
  final Color navMuted;
  final Color navHover;
  final Color navSelectedBg;
  final Color navSelectedForeground;
  final Color navAvatar;
  final Color navBorder;
  final Color heroStart;
  final Color heroEnd;
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
  Color get navAvatarFg => navSelectedForeground;
  Color get ink => text;
  Color get ink3 => textSecondary;
  Color get ink4 => textMuted;
  Color get scrim => overlay;
  Color get greenDark => success;
  Color get greenTint => successContainer;
  Color get amberTint => warningContainer;
  Color get red => error;
  Color get redTint => errorContainer;
  Color get primaryDeep => brand;
  Color get primaryTint => brandContainer;
  Color get borderHover => borderStrong;
  List<BoxShadow> get toastShadow => popoverShadow;

  @override
  SrColors copyWith({
    Color? brand,
    Color? brandHover,
    Color? brandPressed,
    Color? onBrand,
    Color? secondary,
    Color? accent,
    Color? onAccent,
    Color? brandContainer,
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
    Color? infoLine,
    Color? primarySoft,
    Color? primaryLine,
    Color? primaryTint2,
    Color? mapBg,
    Color? navBg,
    Color? navForeground,
    Color? navMuted,
    Color? navHover,
    Color? navSelectedBg,
    Color? navSelectedForeground,
    Color? navAvatar,
    Color? navBorder,
    Color? heroStart,
    Color? heroEnd,
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
    brandHover: brandHover ?? this.brandHover,
    brandPressed: brandPressed ?? this.brandPressed,
    onBrand: onBrand ?? this.onBrand,
    secondary: secondary ?? this.secondary,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    brandContainer: brandContainer ?? this.brandContainer,
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
    infoLine: infoLine ?? this.infoLine,
    primarySoft: primarySoft ?? this.primarySoft,
    primaryLine: primaryLine ?? this.primaryLine,
    primaryTint2: primaryTint2 ?? this.primaryTint2,
    mapBg: mapBg ?? this.mapBg,
    navBg: navBg ?? this.navBg,
    navForeground: navForeground ?? this.navForeground,
    navMuted: navMuted ?? this.navMuted,
    navHover: navHover ?? this.navHover,
    navSelectedBg: navSelectedBg ?? this.navSelectedBg,
    navSelectedForeground: navSelectedForeground ?? this.navSelectedForeground,
    navAvatar: navAvatar ?? this.navAvatar,
    navBorder: navBorder ?? this.navBorder,
    heroStart: heroStart ?? this.heroStart,
    heroEnd: heroEnd ?? this.heroEnd,
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
      brandHover: blend(brandHover, other.brandHover),
      brandPressed: blend(brandPressed, other.brandPressed),
      onBrand: blend(onBrand, other.onBrand),
      secondary: blend(secondary, other.secondary),
      accent: blend(accent, other.accent),
      onAccent: blend(onAccent, other.onAccent),
      brandContainer: blend(brandContainer, other.brandContainer),
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
      infoLine: blend(infoLine, other.infoLine),
      primarySoft: blend(primarySoft, other.primarySoft),
      primaryLine: blend(primaryLine, other.primaryLine),
      primaryTint2: blend(primaryTint2, other.primaryTint2),
      mapBg: blend(mapBg, other.mapBg),
      navBg: blend(navBg, other.navBg),
      navForeground: blend(navForeground, other.navForeground),
      navMuted: blend(navMuted, other.navMuted),
      navHover: blend(navHover, other.navHover),
      navSelectedBg: blend(navSelectedBg, other.navSelectedBg),
      navSelectedForeground: blend(
        navSelectedForeground,
        other.navSelectedForeground,
      ),
      navAvatar: blend(navAvatar, other.navAvatar),
      navBorder: blend(navBorder, other.navBorder),
      heroStart: blend(heroStart, other.heroStart),
      heroEnd: blend(heroEnd, other.heroEnd),
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
    final generatedScheme = ColorScheme.fromSeed(
      brightness: brightness,
      seedColor: colors.brand,
      primary: colors.brand,
      secondary: colors.accent,
      tertiary: colors.secondary,
      error: colors.error,
      surface: colors.surface,
    );
    final scheme = generatedScheme.copyWith(
      primary: colors.brand,
      onPrimary: colors.onBrand,
      primaryContainer: colors.brandContainer,
      onPrimaryContainer: colors.primaryDeep,
      secondary: colors.accent,
      onSecondary: colors.onAccent,
      secondaryContainer: colors.warningContainer,
      onSecondaryContainer: colors.warning,
      tertiary: colors.secondary,
      onTertiary: dark ? colors.surfaceSunken : colors.onAccent,
      error: colors.error,
      onError: dark ? colors.surfaceSunken : colors.surface,
      errorContainer: colors.errorContainer,
      onErrorContainer: colors.redInk,
      surface: colors.surface,
      onSurface: colors.text,
      outline: colors.borderStrong,
      outlineVariant: colors.border,
      shadow: colors.overlay,
      scrim: colors.overlay,
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
          color: dark ? colors.accent : colors.text,
          borderRadius: BorderRadius.circular(SR.rSm),
        ),
        textStyle: SrType.caption(
          color: dark ? colors.onAccent : colors.surface,
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
          backgroundColor: colors.brand,
          foregroundColor: colors.onBrand,
          disabledBackgroundColor: colors.surfaceSunken,
          disabledForegroundColor: colors.textMuted,
          elevation: 0,
          minimumSize: const Size(64, SR.controlLg),
          textStyle: SrType.button(color: colors.onBrand),
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
          foregroundColor: colors.brand,
          disabledForegroundColor: colors.textMuted,
          minimumSize: const Size(48, SR.controlMd),
          textStyle: SrType.button(color: colors.brand),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SR.rSm),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colors.brand,
        foregroundColor: colors.onBrand,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        extendedTextStyle: SrType.button(color: colors.onBrand),
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
        indicatorColor: colors.brandContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => SrType.caption(
            w: 600,
            color: states.contains(WidgetState.selected)
                ? colors.brand
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
        color: colors.brand,
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

  IconData get _icon => switch (value) {
    SrThemePreference.system => Icons.brightness_auto_rounded,
    SrThemePreference.light => Icons.light_mode_rounded,
    SrThemePreference.dark => Icons.dark_mode_rounded,
  };

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return PopupMenuButton<SrThemePreference>(
        tooltip: 'Appearance: ${value.label}',
        onSelected: onChanged,
        itemBuilder: (context) => [
          for (final preference in SrThemePreference.values)
            CheckedPopupMenuItem(
              value: preference,
              checked: preference == value,
              child: Row(
                children: [
                  Icon(switch (preference) {
                    SrThemePreference.system => Icons.brightness_auto_rounded,
                    SrThemePreference.light => Icons.light_mode_rounded,
                    SrThemePreference.dark => Icons.dark_mode_rounded,
                  }, size: 18),
                  const SizedBox(width: 10),
                  Text(preference.label),
                ],
              ),
            ),
        ],
        child: Semantics(
          button: true,
          label: 'Appearance: ${value.label}',
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.srColors.surface,
              borderRadius: BorderRadius.circular(SR.rSm),
              border: Border.all(color: context.srColors.border),
            ),
            child: Icon(_icon, size: 19, color: context.srColors.ink2),
          ),
        ),
      );
    }
    return SegmentedButton<SrThemePreference>(
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
            label: Text(preference.label),
            tooltip: '${preference.label} appearance',
          ),
      ],
      selected: {value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
