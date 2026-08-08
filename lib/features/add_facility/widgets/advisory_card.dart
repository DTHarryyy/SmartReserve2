import 'package:flutter/material.dart';

import '../../../theme/sr_tokens.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

class AdvisoryCard extends StatelessWidget {
  const AdvisoryCard({super.key, required this.advisory});

  final MapAdvisory advisory;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: ValueKey(advisory.title),
    tween: Tween(begin: 0, end: 1),
    duration: SR.entrance,
    curve: SR.easing,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 6), child: child),
    ),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: advisory.background,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: advisory.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: advisory.iconBackground,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(advisory.icon, size: 12, color: advisory.foreground),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  advisory.title,
                  style: sans(12, w: 600, color: advisory.foreground),
                ),
                const SizedBox(height: 2),
                Text(
                  advisory.body,
                  style: sans(
                    11.5,
                    height: 1.55,
                    color: advisory.bodyForeground,
                  ),
                ),
                if (advisory.actions.isNotEmpty) ...[
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final action in advisory.actions)
                        _ActionButton(
                          action: action,
                          accent: advisory.foreground,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.accent});

  final AdvisoryAction action;
  final Color accent;

  @override
  Widget build(BuildContext context) => Hoverable(
    builder: (context, hovered) => GestureDetector(
      onTap: action.onPressed,
      child: AnimatedContainer(
        duration: SR.stateChange,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: action.primary
              ? accent
              : (hovered ? SR.surface : const Color(0xB3FFFFFF)),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: accent.withValues(alpha: .45)),
        ),
        child: Text(
          action.label,
          style: sans(11, w: 600, color: action.primary ? SR.surface : accent),
        ),
      ),
    ),
  );
}
