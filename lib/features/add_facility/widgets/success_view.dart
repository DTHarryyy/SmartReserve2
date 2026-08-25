import 'package:flutter/material.dart';

import '../../../theme/sr_tokens.dart';
import '../../../util/geo.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

import '../../../theme/sr_theme.dart';

class SuccessView extends StatelessWidget {
  const SuccessView({
    super.key,
    required this.controller,
    required this.onBackToList,
  });

  final AddFacilityController controller;
  final VoidCallback onBackToList;

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    return Container(
      color: context.srColors.bg,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: SR.easing,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 6),
                child: child,
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: context.srColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.srColors.border),
                boxShadow: SR.cardShadow,
              ),
              child: Column(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.srColors.greenTint,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 24,
                      color: context.srColors.greenDark,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${controller.savedName} is live',
                    textAlign: TextAlign.center,
                    style: sans(18, w: 600, tracking: -.015),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Pinned and published. Students can now find it and get '
                    'walking directions from any campus gate.',
                    textAlign: TextAlign.center,
                    style: sans(
                      12.5,
                      height: 1.6,
                      color: context.srColors.ink4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SrCellGrid(
                    columns: 2,
                    children: [
                      SrKeyCell(
                        label: 'COORDINATES',
                        value: draft.pin == null
                            ? '—'
                            : formatCoords(draft.pin!),
                        valueMono: true,
                      ),
                      SrKeyCell(
                        label: 'PIN ACCURACY',
                        value: '±${draft.accuracy ?? 0} m',
                        valueMono: true,
                      ),
                      SrKeyCell(
                        label: 'BUILDING',
                        value: draft.building.isEmpty ? '—' : draft.building,
                      ),
                      SrKeyCell(
                        label: 'CAPACITY',
                        value:
                            '${draft.capacitySeats ?? 0} seats · '
                            '${draft.daysLine}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SrButton(
                        label: 'Add another facility',
                        kind: SrButtonKind.primary,
                        onPressed: controller.startAnother,
                      ),
                      SrButton(
                        label: 'Back to facilities',
                        onPressed: onBackToList,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
