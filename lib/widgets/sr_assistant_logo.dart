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

  static const _lightAssetName = 'assets/smart reserve logo.png';
  static const _darkAssetName =
      'assets/smart reserve logo transpatent.png';

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

    final logo = Image.asset(
      colors.isDark ? _darkAssetName : _lightAssetName,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(padding ?? size * .11),
      decoration: BoxDecoration(
        color: resolvedBackground,
        borderRadius: BorderRadius.circular(radius ?? size * .5),
        border: Border.all(color: resolvedBorder),
      ),
      child: logo,
    );
  }
}
