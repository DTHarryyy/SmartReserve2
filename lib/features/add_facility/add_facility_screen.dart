import 'package:flutter/material.dart';

import '../../app/app_shell.dart';
import '../../model/facility_draft.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_controls.dart';
import 'add_facility_controller.dart';
import 'form_rail.dart';
import 'map_pane.dart';
import 'widgets/mobile_pin_sheet.dart';
import 'widgets/success_view.dart';

class AddFacilityBody extends StatelessWidget {
  const AddFacilityBody({
    super.key,
    required this.controller,
    required this.layout,
    required this.onSave,
    required this.onBackToList,
  });

  final AddFacilityController controller;
  final Layout layout;
  final VoidCallback onSave;
  final VoidCallback onBackToList;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (controller.saved) {
        return SuccessView(controller: controller, onBackToList: onBackToList);
      }
      return Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                Expanded(child: _rails(context)),
                if (layout.isMobile)
                  _MobileBar(
                    controller: controller,
                    onOpenMap: () => MobilePinSheet.open(context, controller),
                    onSave: onSave,
                  ),
              ],
            ),
          ),
          if (controller.fullscreenMap && !layout.isMobile)
            Positioned.fill(
              child: ColoredBox(
                color: SR.bg,
                child: SafeArea(
                  child: MapPane(
                    controller: controller,
                    padding: const EdgeInsets.all(16),
                    compact: layout.belowDesktop,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _rails(BuildContext context) => switch (layout) {
    Layout.desktop => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: SR.border)),
            ),
            child: FormRail(
              controller: controller,
              stacked: false,
              dense: false,
              photoColumns: 3,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
            ),
          ),
        ),
        Expanded(
          child: MapPane(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 20, 24, 24),
          ),
        ),
      ],
    ),

    Layout.tablet =>
      SR.isShort(MediaQuery.sizeOf(context).height)
          ? FormRail(
              controller: controller,
              stacked: false,
              dense: true,
              photoColumns: 3,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            )
          : Column(
              children: [
                MapPane(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  compact: true,
                  strip: true,
                  showFooter: false,
                ),
                Expanded(
                  child: FormRail(
                    controller: controller,
                    stacked: false,
                    dense: true,
                    photoColumns: 3,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  ),
                ),
              ],
            ),

    Layout.mobile => FormRail(
      controller: controller,
      stacked: true,
      dense: true,
      photoColumns: 2,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
    ),
  };
}

class _MobileBar extends StatelessWidget {
  const _MobileBar({
    required this.controller,
    required this.onOpenMap,
    required this.onSave,
  });

  final AddFacilityController controller;
  final VoidCallback onOpenMap;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    decoration: BoxDecoration(
      color: SR.surface,
      border: Border(top: BorderSide(color: SR.border)),
      boxShadow: SR.cardShadow,
    ),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${controller.draft.completeCount} of '
                  '${RequiredItem.values.length} ready',
                  style: sans(11.5, w: 600),
                ),
                Text(
                  controller.coordLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(10.5, color: SR.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SrButton(
            label: 'Pin on map',
            minHeight: 44,
            fontSize: 12.5,
            onPressed: onOpenMap,
          ),
          const SizedBox(width: 8),
          SrButton(
            label: controller.saving ? 'Saving…' : 'Save',
            kind: SrButtonKind.primary,
            minHeight: 44,
            fontSize: 12.5,
            onPressed: controller.saving ? null : onSave,
          ),
        ],
      ),
    ),
  );
}
