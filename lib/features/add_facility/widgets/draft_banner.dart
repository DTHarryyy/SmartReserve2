import 'package:flutter/material.dart';

import '../../../theme/sr_tokens.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

import '../../../theme/sr_theme.dart';

class DraftBanner extends StatelessWidget {
  const DraftBanner({super.key, required this.controller});

  final AddFacilityController controller;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    decoration: BoxDecoration(
      color: context.srColors.amberTint,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: context.srColors.amberLine),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.srColors.amberIcon,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('↺', style: sans(11, color: context.srColors.amber)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Unsaved draft from ${controller.draftAge}',
                style: sans(12.5, w: 600, color: context.srColors.amberTitle),
              ),
              const SizedBox(height: 2),
              Text(
                '“${controller.draftPreviewName}” was left unfinished, '
                'including its map pin.',
                style: sans(
                  11.5,
                  height: 1.55,
                  color: context.srColors.amberInk,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _BannerButton(
                    label: 'Restore draft',
                    onPressed: controller.restoreDraft,
                    solid: true,
                  ),
                  const SizedBox(width: 8),
                  _BannerButton(
                    label: 'Start fresh',
                    onPressed: controller.dropStoredDraft,
                    solid: false,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _BannerButton extends StatelessWidget {
  const _BannerButton({
    required this.label,
    required this.onPressed,
    required this.solid,
  });

  final String label;
  final VoidCallback onPressed;
  final bool solid;

  @override
  Widget build(BuildContext context) => Hoverable(
    builder: (context, hovered) => GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: SR.stateChange,
        constraints: BoxConstraints(
          minHeight: SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: solid
              ? context.srColors.amber
              : (hovered ? context.srColors.amberIcon : Colors.transparent),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: solid ? context.srColors.amber : context.srColors.amberLine2,
          ),
        ),
        child: Text(
          label,
          style: sans(
            11,
            w: solid ? 600 : 500,
            color: solid
                ? context.srColors.surface
                : context.srColors.amberTitle,
          ),
        ),
      ),
    ),
  );
}
