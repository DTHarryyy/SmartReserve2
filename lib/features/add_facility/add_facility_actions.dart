import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/notices.dart';
import 'add_facility_controller.dart';

Future<void> saveFacility(
  BuildContext context,
  AppState state,
  AddFacilityController controller,
) async {
  final editingId = controller.editingId;
  final ok = await controller.save(existingFacilities: state.facilities);
  if (!ok) {
    jumpToFirstIssue(controller);
    return;
  }

  try {
    final facility = await state.persistFacility(
      controller.draft,
      editingId: editingId,
    );
    await controller.completeSave(facility.name);

    if (editingId != null) {
      controller
        ..editingId = null
        ..saved = false
        ..startNewRecord();
      state
        ..showToast(ToastMessage('${facility.name} updated.'))
        ..goTo(AppView.facilities);
    }
  } catch (error) {
    controller.failSave();
    state.showToast(
      ToastMessage(
        'Facility could not be saved: $error',
        tone: AdvisoryTone.block,
      ),
    );
  }
}

void jumpToFirstIssue(AddFacilityController controller) {
  final item = controller.firstMissing;
  if (item == null) return;
  final target = controller.sectionKeys[item]?.currentContext;
  if (target == null) return;
  Scrollable.ensureVisible(
    target,
    duration: SR.entrance,
    curve: SR.easing,
    alignment: .08,
  );
}

Future<void> cancelEdit(
  BuildContext context,
  AppState state,
  AddFacilityController controller,
) async {
  if (!controller.isDirty) {
    controller.startNewRecord();
    state.goTo(AppView.facilities);
    return;
  }

  final choice = await showDialog<String>(
    context: context,
    barrierColor: SR.scrimSoft,
    builder: (dialogContext) => GuardDialog(
      hasStoredDraft: controller.draftSavedAt != null,
      onStay: () => Navigator.of(dialogContext).pop('stay'),
      onKeepDraft: () => Navigator.of(dialogContext).pop('keep'),
      onDiscard: () => Navigator.of(dialogContext).pop('discard'),
    ),
  );

  switch (choice) {
    case 'keep':
      await controller.leaveKeepingDraft();
      state.goTo(AppView.facilities);
    case 'discard':
      await controller.discardEverything();
      state.goTo(AppView.facilities);
  }
}
