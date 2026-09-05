// The context-free helpers below (sans, mono, SrType, SrTone) have no
// BuildContext to read context.srColors from and are called from thousands
// of sites across the app, so they intentionally keep reading the legacy
// SR.* static bridge (theme-aware via SR.activate) rather than the
// per-context SrColors extension.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/material.dart';

import 'sr_theme.dart';

abstract final class SR {
  static const primary = Color(0xFF1A73E8);

  static const primaryHover = Color(0xFF1765CC);

  static const primaryPressed = Color(0xFF1254AD);

  @Deprecated('Use context.srColors.primaryDeep instead.')
  static Color get primaryDeep =>
      _dark ? SrColors.dark.primaryDeep : SrColors.light.primaryDeep;

  @Deprecated('Use context.srColors.primaryTint instead.')
  static Color get primaryTint =>
      _dark ? SrColors.dark.primaryTint : SrColors.light.primaryTint;

  @Deprecated('Use context.srColors.primaryTint2 instead.')
  static Color get primaryTint2 =>
      _dark ? SrColors.dark.primaryTint2 : SrColors.light.primaryTint2;

  @Deprecated('Use context.srColors.primaryLine instead.')
  static Color get primaryLine =>
      _dark ? SrColors.dark.primaryLine : SrColors.light.primaryLine;

  @Deprecated('Use context.srColors.primarySoft instead.')
  static Color get primarySoft =>
      _dark ? SrColors.dark.primarySoft : SrColors.light.primarySoft;

  static const primaryBright = Color(0xFF00B4FF);

  static const secondary = Color(0xFF00B4FF);
  static const accent = Color(0xFF00E0C7);
  static const neutralDark = Color(0xFF0B1B33);

  static bool _dark = false;

  /// Keeps the legacy static token API theme-aware while screens migrate to
  /// [SrColors]. [SrThemeBridge] updates this before its descendants build.
  static void activate(Brightness brightness) {
    _dark = brightness == Brightness.dark;
  }

  @Deprecated('Use context.srColors.isDark instead.')
  static bool get isDark => _dark;

  @Deprecated('Use context.srColors.bg instead.')
  static Color get bg => _dark ? SrColors.dark.bg : SrColors.light.bg;
  @Deprecated('Use context.srColors.surface instead.')
  static Color get surface =>
      _dark ? SrColors.dark.surface : SrColors.light.surface;
  @Deprecated('Use context.srColors.surfaceSubtle instead.')
  static Color get surfaceSubtle =>
      _dark ? SrColors.dark.surfaceSubtle : SrColors.light.surfaceSubtle;
  @Deprecated('Use context.srColors.surfaceSunken instead.')
  static Color get surfaceSunken =>
      _dark ? SrColors.dark.surfaceSunken : SrColors.light.surfaceSunken;
  @Deprecated('Use context.srColors.mapBg instead.')
  static Color get mapBg => _dark ? SrColors.dark.mapBg : SrColors.light.mapBg;

  @Deprecated('Use context.srColors.navBg instead.')
  static Color get navBg => _dark ? SrColors.dark.navBg : SrColors.light.navBg;
  @Deprecated('Use context.srColors.navBorder instead.')
  static Color get navBorder =>
      _dark ? SrColors.dark.navBorder : SrColors.light.navBorder;
  @Deprecated('Use context.srColors.navAvatar instead.')
  static Color get navAvatar =>
      _dark ? SrColors.dark.navAvatar : SrColors.light.navAvatar;
  @Deprecated('Use context.srColors.navAvatarFg instead.')
  static Color get navAvatarFg =>
      _dark ? SrColors.dark.navAvatarFg : SrColors.light.navAvatarFg;

  @Deprecated('Use context.srColors.border instead.')
  static Color get border =>
      _dark ? SrColors.dark.border : SrColors.light.border;
  @Deprecated('Use context.srColors.borderField instead.')
  static Color get borderField =>
      _dark ? SrColors.dark.borderField : SrColors.light.borderField;
  @Deprecated('Use context.srColors.borderHover instead.')
  static Color get borderHover =>
      _dark ? SrColors.dark.borderHover : SrColors.light.borderHover;
  @Deprecated('Use context.srColors.hairline instead.')
  static Color get hairline =>
      _dark ? SrColors.dark.hairline : SrColors.light.hairline;
  @Deprecated('Use context.srColors.divider instead.')
  static Color get divider =>
      _dark ? SrColors.dark.divider : SrColors.light.divider;
  @Deprecated('Use context.srColors.dividerSoft instead.')
  static Color get dividerSoft =>
      _dark ? SrColors.dark.dividerSoft : SrColors.light.dividerSoft;
  @Deprecated('Use context.srColors.dashed instead.')
  static Color get dashed =>
      _dark ? SrColors.dark.dashed : SrColors.light.dashed;

  @Deprecated('Use context.srColors.ink instead.')
  static Color get ink => _dark ? SrColors.dark.ink : SrColors.light.ink;
  @Deprecated('Use context.srColors.ink2 instead.')
  static Color get ink2 => _dark ? SrColors.dark.ink2 : SrColors.light.ink2;
  @Deprecated('Use context.srColors.ink3 instead.')
  static Color get ink3 => _dark ? SrColors.dark.ink3 : SrColors.light.ink3;
  @Deprecated('Use context.srColors.ink4 instead.')
  static Color get ink4 => _dark ? SrColors.dark.ink4 : SrColors.light.ink4;
  @Deprecated('Use context.srColors.muted instead.')
  static Color get muted => _dark ? SrColors.dark.muted : SrColors.light.muted;
  @Deprecated('Use context.srColors.mutedLight instead.')
  static Color get mutedLight =>
      _dark ? SrColors.dark.mutedLight : SrColors.light.mutedLight;

  static const onDark = Color(0xFFFFFFFF);
  static const onDarkStrong = Color(0xE6FFFFFF);
  static const onDarkMuted = Color(0x9EFFFFFF);
  static const onDarkFaint = Color(0x66FFFFFF);
  static const onDarkDim = Color(0x4DFFFFFF);
  static const onDarkLine = Color(0x14FFFFFF);
  static const onDarkFill = Color(0x12FFFFFF);
  static const onDarkFillStrong = Color(0x1FFFFFFF);

  @Deprecated('Use context.srColors.scrim instead.')
  static Color get scrim => _dark ? SrColors.dark.scrim : SrColors.light.scrim;
  @Deprecated('Use context.srColors.scrimSoft instead.')
  static Color get scrimSoft =>
      _dark ? SrColors.dark.scrimSoft : SrColors.light.scrimSoft;
  @Deprecated('Use context.srColors.glass instead.')
  static Color get glass => _dark ? SrColors.dark.glass : SrColors.light.glass;
  @Deprecated('Use context.srColors.glassLine instead.')
  static Color get glassLine =>
      _dark ? SrColors.dark.glassLine : SrColors.light.glassLine;
  @Deprecated('Use context.srColors.glassLine2 instead.')
  static Color get glassLine2 =>
      _dark ? SrColors.dark.glassLine2 : SrColors.light.glassLine2;

  static const green = Color(0xFF12B76A);
  @Deprecated('Use context.srColors.greenDark instead.')
  static Color get greenDark =>
      _dark ? SrColors.dark.greenDark : SrColors.light.greenDark;
  @Deprecated('Use context.srColors.greenDeep instead.')
  static Color get greenDeep =>
      _dark ? SrColors.dark.greenDeep : SrColors.light.greenDeep;
  @Deprecated('Use context.srColors.greenTint instead.')
  static Color get greenTint =>
      _dark ? SrColors.dark.greenTint : SrColors.light.greenTint;
  @Deprecated('Use context.srColors.greenTint2 instead.')
  static Color get greenTint2 =>
      _dark ? SrColors.dark.greenTint2 : SrColors.light.greenTint2;
  @Deprecated('Use context.srColors.greenLine instead.')
  static Color get greenLine =>
      _dark ? SrColors.dark.greenLine : SrColors.light.greenLine;

  @Deprecated('Use context.srColors.amber instead.')
  static Color get amber => _dark ? SrColors.dark.amber : SrColors.light.amber;
  @Deprecated('Use context.srColors.amberTint instead.')
  static Color get amberTint =>
      _dark ? SrColors.dark.amberTint : SrColors.light.amberTint;
  @Deprecated('Use context.srColors.amberLine instead.')
  static Color get amberLine =>
      _dark ? SrColors.dark.amberLine : SrColors.light.amberLine;
  @Deprecated('Use context.srColors.amberLine2 instead.')
  static Color get amberLine2 =>
      _dark ? SrColors.dark.amberLine2 : SrColors.light.amberLine2;
  @Deprecated('Use context.srColors.amberIcon instead.')
  static Color get amberIcon =>
      _dark ? SrColors.dark.amberIcon : SrColors.light.amberIcon;
  @Deprecated('Use context.srColors.amberInk instead.')
  static Color get amberInk =>
      _dark ? SrColors.dark.amberInk : SrColors.light.amberInk;
  @Deprecated('Use context.srColors.amberTitle instead.')
  static Color get amberTitle =>
      _dark ? SrColors.dark.amberTitle : SrColors.light.amberTitle;
  static const orange = Color(0xFFF79009);

  @Deprecated('Use context.srColors.red instead.')
  static Color get red => _dark ? SrColors.dark.red : SrColors.light.red;
  @Deprecated('Use context.srColors.redTint instead.')
  static Color get redTint =>
      _dark ? SrColors.dark.redTint : SrColors.light.redTint;
  @Deprecated('Use context.srColors.redLine instead.')
  static Color get redLine =>
      _dark ? SrColors.dark.redLine : SrColors.light.redLine;
  static const redBright = Color(0xFFF97066);
  @Deprecated('Use context.srColors.redInk instead.')
  static Color get redInk =>
      _dark ? SrColors.dark.redInk : SrColors.light.redInk;
  @Deprecated('Use context.srColors.redInk2 instead.')
  static Color get redInk2 =>
      _dark ? SrColors.dark.redInk2 : SrColors.light.redInk2;

  @Deprecated('Use SR.primary')
  static const blue = primary;
  @Deprecated('Use SR.primaryHover')
  static const blueDark = primaryHover;
  @Deprecated('Use SR.primaryDeep')
  static Color get blueInk => primaryDeep;
  @Deprecated('Use SR.primaryTint')
  static Color get blueTint => primaryTint;
  @Deprecated('Use SR.primaryTint2')
  static Color get blueTint2 => primaryTint2;
  @Deprecated('Use SR.primaryLine')
  static Color get blueLine => primaryLine;
  @Deprecated('Use SR.primarySoft')
  static Color get blueSoft => primarySoft;
  @Deprecated('Use SR.primaryDeep')
  static Color get blueToken => primaryDeep;
  @Deprecated('Use SR.primaryBright')
  static const blueBright = primaryBright;

  static const rXs = 6.0;

  static const rSm = 8.0;

  static const rMd = 12.0;

  static const rLg = 16.0;

  static const rXl = 24.0;

  static const rFull = 999.0;

  static BorderRadius radius(double r) => BorderRadius.circular(r);

  static const space2 = 2.0;
  static const space4 = 4.0;
  static const space6 = 6.0;
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space16 = 16.0;
  static const space20 = 20.0;
  static const space24 = 24.0;
  static const space32 = 32.0;
  static const space40 = 40.0;
  static const space48 = 48.0;

  static const tapTarget = 44.0;

  static const controlSm = 32.0;
  static const controlMd = 40.0;
  static const controlLg = 46.0;

  static const iconSm = 14.0;
  static const iconMd = 18.0;
  static const iconLg = 22.0;

  static List<BoxShadow> get cardShadow => _dark
      ? const []
      : const [
          BoxShadow(
            color: Color(0x100B1B33),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ];

  static List<BoxShadow> get floatShadow => _dark
      ? const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x1A0B1B33),
            blurRadius: 18,
            offset: Offset(0, 5),
          ),
        ];

  static List<BoxShadow> get popoverShadow => _dark
      ? const [
          BoxShadow(
            color: Color(0x8A000000),
            blurRadius: 34,
            offset: Offset(0, 16),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x290B1B33),
            blurRadius: 34,
            offset: Offset(0, 16),
          ),
        ];

  static List<BoxShadow> get dialogShadow => _dark
      ? const [
          BoxShadow(
            color: Color(0xB3000000),
            blurRadius: 70,
            offset: Offset(0, 30),
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x520B1B33),
            blurRadius: 70,
            offset: Offset(0, 30),
          ),
        ];

  static List<BoxShadow> get toastShadow => popoverShadow;

  static const List<BoxShadow> focusRing = [
    BoxShadow(color: Color(0x331A73E8), spreadRadius: 3),
  ];

  static List<BoxShadow> focusRingOf(Color color) => [
    BoxShadow(color: color.withValues(alpha: .20), spreadRadius: 3),
  ];

  static const stateChange = Duration(milliseconds: 160);
  static const entrance = Duration(milliseconds: 220);
  static const progressSweep = Duration(milliseconds: 350);
  static const easing = Cubic(.2, .7, .2, 1);

  static const compactMax = 600.0;

  static const mediumMin = 600.0;

  static const expandedMin = 900.0;

  static const desktopMin = 1180.0;

  static const tabletMin = mediumMin;

  static bool isCompact(double width) => width < compactMax;

  static bool isMedium(double width) =>
      width >= compactMax && width < expandedMin;

  static bool isExpanded(double width) =>
      width >= expandedMin && width < desktopMin;

  static bool isDesktop(double width) => width >= desktopMin;

  static bool fitsSplitView(double width) => width >= expandedMin;

  static bool isShort(double height) => height < 520;

  static const contentTiny = 340.0;
  static const contentNarrow = 420.0;
  static const contentMid = 520.0;
  static const contentWide = 760.0;

  static double pageGutter(double width) => switch (width) {
    < 360 => space12,
    < mediumMin => 14,
    < desktopMin => space20,
    _ => space24,
  };

  static EdgeInsets pageInsets(
    double width, {
    double? top,
    double bottom = space40,
  }) {
    final gutter = pageGutter(width);
    return EdgeInsets.fromLTRB(gutter, top ?? gutter, gutter, bottom);
  }

  static const contentMaxWidth = 1080.0;

  static const dataMaxWidth = 1180.0;
}

enum SrBreakpoint {
  compact,

  medium,

  expanded,

  large;

  static SrBreakpoint of(double width) {
    if (width >= SR.desktopMin) return SrBreakpoint.large;
    if (width >= SR.expandedMin) return SrBreakpoint.expanded;
    if (width >= SR.mediumMin) return SrBreakpoint.medium;
    return SrBreakpoint.compact;
  }

  bool get isCompact => this == SrBreakpoint.compact;
  bool get isLarge => this == SrBreakpoint.large;

  bool get fitsSplitView => index >= SrBreakpoint.expanded.index;

  bool isAtLeast(SrBreakpoint other) => index >= other.index;
}

extension SrBreakpointContext on BuildContext {
  double get viewportWidth => MediaQuery.sizeOf(this).width;

  SrBreakpoint get breakpoint => SrBreakpoint.of(viewportWidth);

  bool get isCompact => breakpoint.isCompact;

  bool get isLarge => breakpoint.isLarge;

  bool get fitsSplitView => breakpoint.fitsSplitView;

  bool isAtLeast(SrBreakpoint other) => breakpoint.isAtLeast(other);

  EdgeInsets get pageInsets => SR.pageInsets(viewportWidth);
}

const _sans = 'Poppins';
const _mono = 'IBM Plex Mono';

FontWeight _weight(int w) => FontWeight.values[(w ~/ 100) - 1];

TextStyle sans(
  double size, {
  int w = 400,
  double? height,
  double tracking = 0,
  Color? color,
  TextDecoration? decoration,
  FontStyle? style,
}) => TextStyle(
  fontFamily: _sans,
  fontSize: size,
  fontWeight: _weight(w),
  height: height,
  letterSpacing: tracking == 0 ? null : size * tracking,
  color: color ?? SR.ink,
  decoration: decoration,
  fontStyle: style,
);

TextStyle mono(
  double size, {
  int w = 400,
  double? height,
  double tracking = 0,
  Color? color,
}) => TextStyle(
  fontFamily: _mono,
  fontSize: size,
  fontWeight: _weight(w),
  height: height,
  letterSpacing: tracking == 0 ? null : size * tracking,
  color: color ?? SR.ink,
);

TextStyle get keyLabel => SrType.overline();

abstract final class SrType {
  static TextStyle display({Color? color}) =>
      sans(28, w: 600, height: 1.15, color: color);

  static TextStyle title({Color? color}) =>
      sans(22, w: 600, height: 1.2, color: color);

  static TextStyle heading({Color? color}) =>
      sans(18, w: 600, height: 1.25, color: color);

  static TextStyle subhead({Color? color}) =>
      sans(15, w: 600, height: 1.3, color: color);

  static TextStyle bodyLg({int w = 400, Color? color}) =>
      sans(16, w: w, height: 1.5, color: color ?? SR.ink2);

  static TextStyle body({int w = 400, Color? color}) =>
      sans(14, w: w, height: 1.5, color: color ?? SR.ink2);

  static TextStyle bodySm({int w = 400, Color? color}) =>
      sans(13, w: w, height: 1.45, color: color ?? SR.ink3);

  static TextStyle caption({int w = 400, Color? color}) =>
      sans(12, w: w, height: 1.4, color: color ?? SR.ink4);

  static TextStyle label({Color? color}) =>
      sans(13, w: 500, color: color ?? SR.ink2);

  static TextStyle button({Color? color}) =>
      sans(13, w: 600, color: color ?? SR.ink2);

  static TextStyle overline({Color? color}) =>
      mono(12, w: 500, color: color ?? SR.muted);

  static TextStyle code({int w = 400, Color? color}) =>
      mono(12, w: w, color: color ?? SR.ink2);
}

enum SrTone {
  neutral,
  brand,
  success,
  warning,
  error,
  info;

  Color get solid => switch (this) {
    SrTone.neutral => SR.muted,
    SrTone.brand => SR.primary,
    SrTone.success => SR.green,
    SrTone.warning => SR.orange,
    SrTone.error => SR.red,
    SrTone.info => SR.primary,
  };

  Color get tint => switch (this) {
    SrTone.neutral => SR.divider,
    SrTone.brand => SR.primaryTint,
    SrTone.success => SR.greenTint,
    SrTone.warning => SR.amberTint,
    SrTone.error => SR.redTint,
    SrTone.info => SR.primaryTint,
  };

  Color get line => switch (this) {
    SrTone.neutral => SR.border,
    SrTone.brand => SR.primaryLine,
    SrTone.success => SR.greenLine,
    SrTone.warning => SR.amberLine,
    SrTone.error => SR.redLine,
    SrTone.info => SR.primaryLine,
  };

  Color get ink => switch (this) {
    SrTone.neutral => SR.ink3,
    SrTone.brand => SR.primaryDeep,
    SrTone.success => SR.greenDark,
    SrTone.warning => SR.amberTitle,
    SrTone.error => SR.redInk,
    SrTone.info => SR.primaryDeep,
  };
}
