import 'package:flutter/material.dart';

import '../../app/sr_toast_controller.dart';
import '../../data/campus_data.dart';
import '../../model/facility_draft.dart';
import '../../model/notice.dart';
import 'safe_change_notifier.dart';

/// Owns amenity search/selection state for the Add Facility editor.
class AmenitiesController extends ChangeNotifier with SafeChangeNotifier {
  AmenitiesController({
    required this.draft,
    required SrToastController toasts,
    required this.onFieldEdited,
  }) : _toasts = toasts;

  final FacilityDraft draft;
  final SrToastController _toasts;

  /// Bridge: notify the coordinator that a field changed, so it can
  /// revalidate and schedule an autosave.
  final VoidCallback onFieldEdited;

  String amenityQuery = '';
  bool amenityOpen = false;
  final amenityField = TextEditingController();
  final amenityFocus = FocusNode();

  @override
  void dispose() {
    amenityField.dispose();
    amenityFocus.dispose();
    super.dispose();
  }

  void _edit(VoidCallback change) {
    change();
    notifyListeners();
    onFieldEdited();
  }

  List<Amenity> get amenityResults {
    final q = amenityQuery.trim().toLowerCase();
    return [
      for (final a in amenities)
        if (q.isEmpty ||
            a.label.toLowerCase().contains(q) ||
            a.group.toLowerCase().contains(q))
          a,
    ];
  }

  bool get amenityNoResults =>
      amenityQuery.trim().isNotEmpty && amenityResults.isEmpty;

  String get amenityPlaceholder => draft.amenities.isEmpty
      ? 'Search amenities — Wi-Fi, projector, PWD access…'
      : 'Add another';

  String get amenityCountLabel => draft.amenities.isEmpty
      ? 'None selected'
      : '${draft.amenities.length} selected';

  void setAmenityQuery(String value) {
    amenityQuery = value;
    amenityOpen = true;
    notifyListeners();
  }

  void openAmenities() {
    amenityOpen = true;
    notifyListeners();
  }

  void closeAmenities() {
    amenityOpen = false;
    notifyListeners();
  }

  void toggleAmenity(String label) => _edit(() {
    if (draft.amenities.contains(label)) {
      draft.amenities.remove(label);
    } else {
      draft.amenities.add(label);
    }
  });

  void removeAmenity(String label) =>
      _edit(() => draft.amenities.remove(label));

  void submitAmenityQuery() {
    final value = amenityQuery.trim();
    if (value.isEmpty) return;
    final existing = amenityResults;
    if (existing.isNotEmpty) {
      toggleAmenity(existing.first.label);
    } else if (!draft.amenities.contains(value)) {
      _edit(() => draft.amenities.add(value));
      showToast(
        ToastMessage(
          '“$value” added as a requested tag. A reviewer confirms new '
          'amenities before they become filterable.',
          tone: AdvisoryTone.info,
        ),
      );
    }
    amenityQuery = '';
    amenityField.clear();

    amenityFocus.requestFocus();
    notifyListeners();
  }

  void showToast(ToastMessage message, {Duration? duration}) =>
      _toasts.show(message, duration: duration);
}
