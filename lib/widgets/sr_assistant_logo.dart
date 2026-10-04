import 'package:flutter/material.dart';

import '../theme/sr_theme.dart';

class SrAssistantLogo extends StatelessWidget {
  const SrAssistantLogo({
    super.key,
    this.size = 40,
    this.radius,
    this.padding,
    this.backgroundColor,
    this.borderColor,
  });

  static const _lightAssetName = 'assets/chat lightmode.jpg';
  static const _darkAssetName = 'assets/chat darkmode.jpg';

  final double size;
  final double? radius;
  final double? padding;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    final resolvedBackground =
        backgroundColor ??
        (colors.isDark ? colors.surfaceElevated : Colors.white);
    final resolvedBorder =
        borderColor ??
        colors.border.withValues(alpha: colors.isDark ? .78 : .66);

    final logo = ClipOval(
      child: Image.asset(
        colors.isDark ? _darkAssetName : _lightAssetName,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        excludeFromSemantics: true,
      ),
    );

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(padding ?? size * .06),
      decoration: BoxDecoration(
        color: resolvedBackground,
        borderRadius: BorderRadius.circular(radius ?? size * .5),
        border: Border.all(color: resolvedBorder),
      ),
      child: logo,
    );
  }
}
