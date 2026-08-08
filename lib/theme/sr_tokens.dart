import 'package:flutter/material.dart';

abstract final class SR {
  static const bg = Color(0xFFF4F5F7);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSubtle = Color(0xFFFBFBFC);
  static const mapBg = Color(0xFFE8EBEF);
  static const navBg = Color(0xFF101418);
  static const navAvatar = Color(0xFF2B3440);
  static const navAvatarFg = Color(0xFFCBD5E1);

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

  static const blue = Color(0xFF1B58A6);
  static const blueDark = Color(0xFF17518C);
  static const blueInk = Color(0xFF2C5A8F);
  static const blueTint = Color(0xFFEFF5FD);
  static const blueTint2 = Color(0xFFF6F9FD);
  static const blueLine = Color(0xFFDBE7F7);
  static const blueSoft = Color(0xFFA9C8EC);
  static const blueToken = Color(0xFF5B82B3);
  static const blueBright = Color(0xFF3B82F6);

  static const green = Color(0xFF12B76A);
  static const greenDark = Color(0xFF0F7A4D);
  static const greenTint = Color(0xFFECFDF3);

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

  static const stateChange = Duration(milliseconds: 160);
  static const entrance = Duration(milliseconds: 220);
  static const progressSweep = Duration(milliseconds: 350);
  static const easing = Cubic(.2, .7, .2, 1);

  static const desktopMin = 1180.0;

  static const tabletMin = 768.0;
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

TextStyle get keyLabel => mono(9, w: 500, tracking: .05, color: SR.muted);
