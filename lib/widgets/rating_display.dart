import 'package:flutter/material.dart';

import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

class SrRatingStars extends StatelessWidget {
  const SrRatingStars({
    super.key,
    required this.average,
    this.count = 0,
    this.dense = false,
    this.showCount = true,
    this.compact = false,
  });

  final double? average;
  final int count;
  final bool dense;
  final bool showCount;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (average == null || count <= 0) return const SizedBox.shrink();
    final c = context.srColors;
    final size = dense ? 13.0 : 16.0;
    final filled = SrTone.warning.solid;
    if (compact) {
      return Semantics(
        label:
            '${average!.toStringAsFixed(1)} out of 5, '
            '$count ${count == 1 ? 'review' : 'reviews'}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, size: size, color: filled),
            const SizedBox(width: 3),
            Text(
              average!.toStringAsFixed(1),
              style: sans(dense ? 11 : 12, w: 600, color: c.text),
            ),
            if (showCount) ...[
              const SizedBox(width: 2),
              Text(
                '· $count',
                style: sans(dense ? 11 : 12, w: 500, color: c.textMuted),
              ),
            ],
          ],
        ),
      );
    }
    return Semantics(
      label:
          '${average!.toStringAsFixed(1)} out of 5, '
          '$count ${count == 1 ? 'review' : 'reviews'}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              average! >= i
                  ? Icons.star_rounded
                  : (average! >= i - 0.5
                        ? Icons.star_half_rounded
                        : Icons.star_outline_rounded),
              size: size,
              color: average! >= i - 0.5 ? filled : c.border,
            ),
          const SizedBox(width: 6),
          Text(
            average!.toStringAsFixed(1),
            style: sans(dense ? 12 : 13, w: 600, color: c.text),
          ),
          if (showCount) ...[
            const SizedBox(width: 4),
            Text(
              '· $count ${count == 1 ? 'review' : 'reviews'}',
              style: sans(dense ? 12 : 13, w: 500, color: c.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class SrRatingInput extends StatelessWidget {
  const SrRatingInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final compact = context.isCompact;
    final target = compact ? SR.tapTarget : 40.0;
    final iconSize = compact ? 30.0 : 32.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 1; i <= 5; i++)
          Hoverable(
            enabled: enabled,
            builder: (context, hovered) => Semantics(
              button: true,
              label: '$i of 5 stars',
              selected: value >= i,
              child: SizedBox(
                width: target,
                height: target,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(target / 2),
                    onTap: enabled ? () => onChanged(i) : null,
                    child: Center(
                      child: Icon(
                        value >= i
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        size: hovered ? iconSize + 2 : iconSize,
                        color: value >= i ? SrTone.warning.solid : c.border,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
