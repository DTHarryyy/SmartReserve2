import 'package:flutter/material.dart';

import '../../model/facility_draft.dart';
import 'safe_change_notifier.dart';

/// Owns the plain form fields of the Add Facility editor (name, category,
/// description, capacity, building/floor/room, rules, days, hours). Kept
/// separate from map/photos/amenities so typing in any of these fields
/// never rebuilds the map or the photo grid.
class FacilityFormController extends ChangeNotifier with SafeChangeNotifier {
  FacilityFormController({
    required this.draft,
    required this.onFieldEdited,
    required this.onBuildingSelected,
    required this.onFacilityNameChanged,
  }) {
    nameField.addListener(_syncName);
    capacityField.addListener(_syncCapacity);
    descriptionField.addListener(_syncDescription);
    roomField.addListener(_syncRoom);
  }

  final FacilityDraft draft;

  /// Bridge: notify the coordinator that a field changed, so it can
  /// revalidate and schedule an autosave.
  final VoidCallback onFieldEdited;

  /// Bridge: user picked a building from the Location dropdown — the
  /// coordinator mirrors it onto the map slice and may auto-center.
  final ValueChanged<String> onBuildingSelected;

  /// Keeps the label attached to the draggable map pin in sync with the
  /// facility-name field without making the whole map listen to this form.
  final ValueChanged<String> onFacilityNameChanged;

  final nameField = TextEditingController();
  final capacityField = TextEditingController();
  final descriptionField = TextEditingController();
  final roomField = TextEditingController();

  @override
  void dispose() {
    nameField.dispose();
    capacityField.dispose();
    descriptionField.dispose();
    roomField.dispose();
    super.dispose();
  }

  void _edit(VoidCallback change) {
    change();
    notifyListeners();
    onFieldEdited();
  }

  void _syncName() {
    _edit(() => draft.name = nameField.text);
    onFacilityNameChanged(draft.name);
  }

  void _syncCapacity() => _edit(() => draft.capacity = capacityField.text);
  void _syncDescription() =>
      _edit(() => draft.description = descriptionField.text);
  void _syncRoom() => _edit(() => draft.room = roomField.text);

  void setCategory(String value) => _edit(() => draft.category = value);
  void setStatus(FacilityStatus value) => _edit(() => draft.status = value);
  void setCampus(String value) => _edit(() => draft.campusName = value);
  void setFloor(String value) => _edit(() => draft.floor = value);
  void setMaxDuration(String value) => _edit(() => draft.maxDuration = value);
  void setAdvance(String value) => _edit(() => draft.advance = value);
  void setBuffer(String value) => _edit(() => draft.buffer = value);

  void setOpenTime(String value) => _edit(() => draft.openTime = value);
  void setCloseTime(String value) => _edit(() => draft.closeTime = value);

  void setBuilding(String value) {
    _edit(() => draft.building = value);
    onBuildingSelected(value);
  }

  /// Set from the map side (search hit / picked facility) — the map
  /// already knows the building and already centers the camera itself,
  /// so this intentionally skips [onBuildingSelected].
  void setBuildingFromMap(String value) => _edit(() => draft.building = value);

  void setNameFromMap(String value) {
    if (nameField.text == value) return;
    nameField.text = value;
    nameField.selection = TextSelection.collapsed(offset: value.length);
  }

  void setRule(String key, bool value) => _edit(() {
    switch (key) {
      case 'approval':
        draft.requiresApproval = value;
      case 'maintenance':
        draft.maintenance = value;

        if (value && draft.status == FacilityStatus.active) {
          draft.status = FacilityStatus.maintenance;
        } else if (!value && draft.status == FacilityStatus.maintenance) {
          draft.status = FacilityStatus.active;
        }
      case 'listing':
        draft.publicListing = value;
    }
  });

  void toggleDay(int index) =>
      _edit(() => draft.days[index] = !draft.days[index]);

  /// Refreshes the text controllers from [draft] after the coordinator
  /// bulk-hydrates it (load-for-editing / restore-draft / reset).
  void syncFieldsFromDraft() {
    nameField.text = draft.name;
    capacityField.text = draft.capacity;
    descriptionField.text = draft.description;
    roomField.text = draft.room;
    notifyListeners();
  }
}
