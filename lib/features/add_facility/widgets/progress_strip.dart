import 'package:flutter/material.dart';

import '../../../model/facility_draft.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

class ProgressStrip extends StatelessWidget {
  const ProgressStrip({
    super.key,
    required this.controller,
    required this.onJump,
  });

  final AddFacilityController controller;
  final void Function(RequiredItem) onJump;

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: SR.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final summary = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  Text(
                    '${draft.completeCount} of ${RequiredItem.values.length} '
                    'required items ready',
                    style: sans(12, w: 600),
                  ),
                  Text(draft.completePct, style: mono(10.5, color: SR.muted)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  children: [
                    Container(height: 4, color: SR.hairline),
                    LayoutBuilder(
                      builder: (context, constraints) => AnimatedContainer(
                        duration: SR.progressSweep,
                        curve: SR.easing,
                        height: 4,
                        width: constraints.maxWidth * draft.completeFraction,
                        decoration: BoxDecoration(
                          color: SR.blue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final chips = Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              for (final item in RequiredItem.values)
                _Chip(
                  item: item,
                  done: draft.has(item),
                  failing: controller.errors.containsKey(item),
                  onTap: () => onJump(item),
                ),
            ],
          );
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 12), chips],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: 12),
              chips,
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.item,
    required this.done,
    required this.failing,
    required this.onTap,
  });

  final RequiredItem item;
  final bool done;
  final bool failing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, bd) = failing
        ? (SR.redTint, SR.red, SR.redLine)
        : done
        ? (SR.blue, SR.surface, SR.blueDark)
        : (SR.surface, SR.muted, SR.border);
    return Tooltip(
      message: done ? '${item.label} — ready' : '${item.label} — still needed',
      child: Semantics(
        button: true,
        label: '${item.label}, ${done ? 'ready' : 'still needed'}',
        child: SizedBox.square(
          dimension: SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 22,
          child: Hoverable(
            builder: (context, hovered) => GestureDetector(
              onTap: onTap,
              child: Center(
                child: AnimatedContainer(
                  duration: SR.stateChange,
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: hovered ? SR.borderHover : bd),
                  ),
                  child: done
                      ? Icon(Icons.check_rounded, size: 12, color: fg)
                      : Text(
                          '${item.ordinal}',
                          style: mono(9, w: 500, color: fg),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
