import 'package:flutter/material.dart';

abstract final class SR {
  static const primary = Color(0xFF6367FF);

  static const primaryHover = Color(0xFF5457E8);

  static const primaryPressed = Color(0xFF4548C9);

  static const primaryDeep = Color(0xFF4F52D9);

  static const primaryTint = Color(0xFFEEEFFF);

  static const primaryTint2 = Color(0xFFF7F7FF);

  static const primaryLine = Color(0xFFD6D8FF);

  static const primarySoft = Color(0xFFA9ABFF);

  static const primaryBright = Color(0xFF8083FF);

  static const bg = Color(0xFFF5F6F8);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSubtle = Color(0xFFFAFAFC);
  static const surfaceSunken = Color(0xFFF0F1F4);
  static const mapBg = Color(0xFFE8EBEF);

  static const navBg = Color(0xFFFFFFFF);
  static const navBorder = Color(0xFFE9EAEE);
  static const navAvatar = Color(0xFFEEEFFF);
  static const navAvatarFg = Color(0xFF4F52D9);

  static const border = Color(0xFFE4E7EC);
  static const borderField = Color(0xFFDFE3E8);
  static const borderHover = Color(0xFFC3C9D2);
  static const hairline = Color(0xFFEFF1F4);
  static const divider = Color(0xFFF2F4F7);
  static const dividerSoft = Color(0xFFF4F5F7);
  static const dashed = Color(0xFFD0D5DD);

  static const ink = Color(0xFF10141A);
  static const ink2 = Color(0xFF344054);
  static const ink3 = Color(0xFF475467);
  static const ink4 = Color(0xFF667085);
  static const muted = Color(0xFF98A2B3);
  static const mutedLight = Color(0xFFC3C9D2);

  static const onDark = Color(0xFFFFFFFF);
  static const onDarkStrong = Color(0xE6FFFFFF);
  static const onDarkMuted = Color(0x9EFFFFFF);
  static const onDarkFaint = Color(0x66FFFFFF);
  static const onDarkDim = Color(0x4DFFFFFF);
  static const onDarkLine = Color(0x14FFFFFF);
  static const onDarkFill = Color(0x12FFFFFF);
  static const onDarkFillStrong = Color(0x1FFFFFFF);

  static const scrim = Color(0x7010141A);
  static const scrimSoft = Color(0x6B10141A);
  static const glass = Color(0xF7FFFFFF);
  static const glassLine = Color(0x1410141A);
  static const glassLine2 = Color(0x1F10141A);

  static const green = Color(0xFF12B76A);
  static const greenDark = Color(0xFF0F7A4D);
  static const greenDeep = Color(0xFF0A5C3A);
  static const greenTint = Color(0xFFECFDF3);
  static const greenTint2 = Color(0xFFF2FDF7);
  static const greenLine = Color(0xFFB7E9CD);

  static const amber = Color(0xFFB45309);
  static const amberTint = Color(0xFFFFFBF2);
  static const amberLine = Color(0xFFF0D9A8);
  static const amberLine2 = Color(0xFFE6D5B4);
  static const amberIcon = Color(0xFFFDF0D5);
  static const amberInk = Color(0xFF8A6535);
  static const amberTitle = Color(0xFF7A4A09);
  static const orange = Color(0xFFF79009);

  static const red = Color(0xFFB42318);
  static const redTint = Color(0xFFFEF3F2);
  static const redLine = Color(0xFFF2C4C0);
  static const redBright = Color(0xFFF97066);
  static const redInk = Color(0xFF912018);
  static const redInk2 = Color(0xFFA4413A);

  @Deprecated('Use SR.primary')
  static const blue = primary;
  @Deprecated('Use SR.primaryHover')
  static const blueDark = primaryHover;
  @Deprecated('Use SR.primaryDeep')
  static const blueInk = primaryDeep;
  @Deprecated('Use SR.primaryTint')
  static const blueTint = primaryTint;
  @Deprecated('Use SR.primaryTint2')
  static const blueTint2 = primaryTint2;
  @Deprecated('Use SR.primaryLine')
  static const blueLine = primaryLine;
  @Deprecated('Use SR.primarySoft')
  static const blueSoft = primarySoft;
  @Deprecated('Use SR.primaryDeep')
  static const blueToken = primaryDeep;
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

  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x0F10141A), blurRadius: 3, offset: Offset(0, 1)),
  ];

  static const List<BoxShadow> floatShadow = [
    BoxShadow(color: Color(0x1A10141A), blurRadius: 14, offset: Offset(0, 4)),
  ];

  static const List<BoxShadow> popoverShadow = [
    BoxShadow(color: Color(0x2910141A), blurRadius: 34, offset: Offset(0, 16)),
  ];

  static const List<BoxShadow> dialogShadow = [
    BoxShadow(color: Color(0x5210141A), blurRadius: 70, offset: Offset(0, 30)),
  ];

  static const List<BoxShadow> toastShadow = [
    BoxShadow(color: Color(0x2910141A), blurRadius: 34, offset: Offset(0, 14)),
  ];

  static const List<BoxShadow> focusRing = [
    BoxShadow(color: Color(0x336367FF), spreadRadius: 3),
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

const _sans = 'IBM Plex Sans';
const _mono = 'IBM Plex Mono';

FontWeight _weight(int w) => FontWeight.values[(w ~/ 100) - 1];

TextStyle sans(
  double size, {
  int w = 400,
  double? height,
  double tracking = 0,
  Color color = SR.ink,
  TextDecoration? decoration,
  FontStyle? style,
}) => TextStyle(
  fontFamily: _sans,
  fontSize: size,
  fontWeight: _weight(w),
  height: height,
  letterSpacing: tracking == 0 ? null : size * tracking,
  color: color,
  decoration: decoration,
  fontStyle: style,
);

TextStyle mono(
  double size, {
  int w = 400,
  double? height,
  double tracking = 0,
  Color color = SR.ink,
}) => TextStyle(
  fontFamily: _mono,
  fontSize: size,
  fontWeight: _weight(w),
  height: height,
  letterSpacing: tracking == 0 ? null : size * tracking,
  color: color,
);

TextStyle get keyLabel => SrType.overline();

abstract final class SrType {
  static TextStyle display({Color color = SR.ink}) =>
      sans(26, w: 600, height: 1.15, tracking: -.02, color: color);

  static TextStyle title({Color color = SR.ink}) =>
      sans(20, w: 600, height: 1.2, tracking: -.015, color: color);

  static TextStyle heading({Color color = SR.ink}) =>
      sans(17, w: 600, height: 1.25, tracking: -.015, color: color);

  static TextStyle subhead({Color color = SR.ink}) =>
      sans(15, w: 600, height: 1.3, color: color);

  static TextStyle bodyLg({int w = 400, Color color = SR.ink2}) =>
      sans(14, w: w, height: 1.5, color: color);

  static TextStyle body({int w = 400, Color color = SR.ink2}) =>
      sans(13, w: w, height: 1.5, color: color);

  static TextStyle bodySm({int w = 400, Color color = SR.ink3}) =>
      sans(12, w: w, height: 1.45, color: color);

  static TextStyle caption({int w = 400, Color color = SR.ink4}) =>
      sans(11, w: w, height: 1.4, color: color);

  static TextStyle label({Color color = SR.ink2}) =>
      sans(12, w: 500, color: color);

  static TextStyle button({Color color = SR.ink2}) =>
      sans(13, w: 600, color: color);

  static TextStyle overline({Color color = SR.muted}) =>
      mono(10, w: 500, tracking: .05, color: color);

  static TextStyle code({int w = 400, Color color = SR.ink2}) =>
      mono(11.5, w: w, color: color);
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
