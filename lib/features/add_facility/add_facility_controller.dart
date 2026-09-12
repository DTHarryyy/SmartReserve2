import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/sr_toast_controller.dart';
import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/facility_draft.dart';
import '../../model/notice.dart';
import '../../theme/sr_tokens.dart';
import 'amenities_controller.dart';
import 'facility_editor_focus.dart';
import 'facility_form_controller.dart';
import 'map_editor_controller.dart';
import 'photos_controller.dart';
import 'safe_change_notifier.dart';

export '../../model/notice.dart' show AdvisoryTone, ToastMessage;
export 'amenities_controller.dart' show AmenitiesController;
export 'facility_form_controller.dart' show FacilityFormController;
export 'map_editor_controller.dart'
    show
        AdvisoryAction,
        GeoState,
        MapAdvisory,
        MapEditorController,
        MapLayer,
        MapTab,
        SearchHit;
export 'photos_controller.dart' show PhotosController;

/// Coordinates the Add Facility editor: owns the shared [FacilityDraft],
/// draft-lifecycle/autosave/save/validation state, and the four
/// independently-listenable sub-controllers ([map], [form], [photos],
/// [amenities]). Widgets should listen to the narrowest sub-controller
/// (or a [Listenable.merge] of a few) that covers what they read, rather
/// than to this coordinator, so an edit in one area of the form never
/// forces an unrelated area (in particular the map) to rebuild.
class AddFacilityController extends ChangeNotifier with SafeChangeNotifier {
  AddFacilityController({required SrToastController toasts})
    : _toasts = toasts {
    map = MapEditorController(
      draft: draft,
      toasts: toasts,
      onBuildingResolvedFromMap: (v) => form.setBuildingFromMap(v),
      onFieldEdited: _onFieldEdited,
    );
    form = FacilityFormController(
      draft: draft,
      onFieldEdited: _onFieldEdited,
      onBuildingSelected: (v) {
        map.setSelectedBuildingLabel(v);
        final b = buildingNamed(v);
        if (b != null && b.mapped && draft.pin == null) {
          map.centerOn(b.coords, zoom: 18);
        }
      },
    );
    photos = PhotosController(
      draft: draft,
      toasts: toasts,
      onFieldEdited: _onFieldEdited,
    );
    amenities = AmenitiesController(
      draft: draft,
      toasts: toasts,
      onFieldEdited: _onFieldEdited,
    );
    _loadStoredDraft();
  }

  final SrToastController _toasts;

  final FacilityDraft draft = FacilityDraft();

  late final MapEditorController map;
  late final FacilityFormController form;
  late final PhotosController photos;
  late final AmenitiesController amenities;

  List<Facility> get availableFacilities => map.availableFacilities;
  set availableFacilities(List<Facility> value) =>
      map.availableFacilities = value;

  Map<RequiredItem, String> errors = const {};
  bool showErrorBar = false;
  bool saving = false;
  bool saved = false;
  String savedName = '';

  bool draftFound = false;
  String draftAge = '';
  String draftPreviewName = '';
  Map<String, dynamic>? _storedDraft;
  DateTime? _storedDraftAt;
  DateTime? draftSavedAt;
  Timer? _autosaveTimer;

  final sectionKeys = {
    for (final item in RequiredItem.values) item: GlobalKey(),
  };
  final ScrollController formScroll = ScrollController();

  String? editingId;

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    map.dispose();
    form.dispose();
    photos.dispose();
    amenities.dispose();
    formScroll.dispose();
    super.dispose();
  }

  /// Bridge invoked by every sub-controller's `_edit()` after mutating a
  /// field. Only fires the coordinator's own [notifyListeners] when the
  /// error set actually changes shape — not on every keystroke — so
  /// widgets that listen directly to the coordinator (the header, the
  /// error bar) don't get rebuilt on unrelated edits. Autosave scheduling
  /// always runs, regardless of whether errors are showing.
  void _onFieldEdited() {
    if (errors.isNotEmpty) {
      final fresh = draft.validate();
      final next = {
        for (final entry in errors.entries)
          if (fresh.containsKey(entry.key)) entry.key: fresh[entry.key]!,
      };
      final changed = !_sameErrors(errors, next);
      errors = next;
      if (errors.isEmpty) showErrorBar = false;
      if (changed) notifyListeners();
    }
    _scheduleAutosave();
  }

  static bool _sameErrors(
    Map<RequiredItem, String> a,
    Map<RequiredItem, String> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void showToast(ToastMessage message, {Duration? duration}) =>
      _toasts.show(message, duration: duration);

  void dismissErrorBar() {
    showErrorBar = false;
    notifyListeners();
  }

  String get errorBarText {
    final n = errors.length;
    return n == 1
        ? '1 required item is still missing.'
        : '$n required items are still missing.';
  }

  RequiredItem? get firstMissing {
    for (final item in RequiredItem.values) {
      if (errors.containsKey(item)) return item;
    }
    return null;
  }

  Future<bool> save({Iterable<Facility> existingFacilities = const []}) async {
    final found = draft.validate(
      facilities: existingFacilities,
      editingId: editingId,
    );
    errors = found;
    if (found.isNotEmpty) {
      showErrorBar = true;
      notifyListeners();
      return false;
    }

    saving = true;
    showErrorBar = false;
    notifyListeners();

    return true;
  }

  Future<void> completeSave(String name) async {
    savedName = name;
    saved = true;
    saving = false;
    await _clearStoredDraft();
    notifyListeners();
  }

  void failSave() {
    saving = false;
    notifyListeners();
  }

  void startAnother() => _resetFields(keepBuilding: true);

  void startNewRecord() {
    editingId = null;
    saved = false;
    savedName = '';
    _resetFields(keepBuilding: false);
  }

  void loadForEditing(Facility facility, {FacilityEditorReason? reason}) {
    editingId = facility.id;
    map.setQualityReason(reason);
    saved = false;
    savedName = '';
    draftFound = false;
    errors = const {};
    showErrorBar = false;

    draft
      ..name = facility.name
      ..category = facility.category
      ..description = facility.description
      ..capacity = '${facility.capacity}'
      ..status = FacilityStatus.fromLabel(
        facility.state == FacilityState.underReview
            ? 'Available'
            : facility.state.label,
      )
      ..campusName = facility.campusName
      ..building = facility.building
      ..floor = facility.floor
      ..room = facility.room
      ..pin = facility.coords
      ..accuracy = facility.accuracy
      ..confirmedOutside = facility.confirmedOutside
      ..geoBuilding = facility.geoBuilding
      ..street = facility.street
      ..barangay = facility.barangay
      ..municipality = facility.municipality
      ..province = facility.province
      ..region = facility.region
      ..country = facility.country
      ..requiresApproval = facility.approvalRequired
      ..maintenance = facility.state == FacilityState.maintenance
      ..publicListing = facility.publicListing
      ..openTime = facility.hours.split('–').first
      ..closeTime = facility.hours.split('–').last
      ..maxDuration = facility.maxDuration
      ..advance = facility.advance
      ..buffer = facility.buffer
      ..days = _daysFromLabel(facility.days);

    draft.amenities
      ..clear()
      ..addAll(facility.amenities);
    draft.geoEdited.clear();
    draft.geoEdited.addAll(facility.geoEdited);
    draft.photos
      ..clear()
      ..addAll(facility.photos);

    form.syncFieldsFromDraft();
    map.hydrateForEditing();
    notifyListeners();
  }

  void focusEditorSection(
    FacilityEditorFocus? focus, {
    FacilityEditorReason? reason,
  }) {
    if (focus == null) return;
    map.setQualityReason(reason ?? map.qualityReason);
    final item = switch (focus) {
      FacilityEditorFocus.location ||
      FacilityEditorFocus.locationAccuracy => RequiredItem.pin,
      FacilityEditorFocus.photos => RequiredItem.photos,
    };
    if (focus != FacilityEditorFocus.photos) map.setTab(MapTab.map);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = sectionKeys[item]?.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        duration: SR.entrance,
        curve: SR.easing,
        alignment: .08,
      );
    });
  }

  static List<bool> _daysFromLabel(String label) {
    const order = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (label.contains('–')) {
      final from = order.indexOf(label.split('–').first.trim());
      final to = order.indexOf(label.split('–').last.trim());
      if (from >= 0 && to >= from) {
        return [for (var i = 0; i < 7; i++) i >= from && i <= to];
      }
    }
    final named = label.split(',').map((d) => d.trim()).toSet();
    return [for (final d in order) named.contains(d)];
  }

  Future<void> leaveKeepingDraft() async {
    await _writeDraft();
    _resetFields(keepBuilding: false);
    await _loadStoredDraft();
    showToast(
      const ToastMessage(
        'Draft saved locally. It will be offered back next time.',
      ),
    );
  }

  Future<void> discardEverything() async {
    _autosaveTimer?.cancel();
    await _clearStoredDraft();
    _storedDraft = null;
    _resetFields(keepBuilding: false);
    draftFound = false;
    notifyListeners();
    showToast(const ToastMessage('Draft discarded.', tone: AdvisoryTone.info));
  }

  void _resetFields({required bool keepBuilding}) {
    final keptBuilding = keepBuilding ? draft.building : '';
    map.setQualityReason(null);
    final keepCampus = draft.campusName;
    final blank = FacilityDraft();
    draft
      ..name = blank.name
      ..category = blank.category
      ..description = blank.description
      ..capacity = blank.capacity
      ..status = blank.status
      ..campusName = keepCampus
      ..building = keptBuilding
      ..floor = blank.floor
      ..room = ''
      ..pin = null
      ..accuracy = null
      ..confirmedOutside = false
      ..geoBuilding = ''
      ..street = ''
      ..barangay = ''
      ..municipality = ''
      ..province = ''
      ..region = ''
      ..country = ''
      ..requiresApproval = blank.requiresApproval
      ..maintenance = blank.maintenance
      ..publicListing = blank.publicListing
      ..days = List<bool>.from(blank.days)
      ..openTime = blank.openTime
      ..closeTime = blank.closeTime
      ..maxDuration = blank.maxDuration
      ..advance = blank.advance
      ..buffer = blank.buffer;
    draft.photos.clear();
    draft.amenities.clear();
    draft.geoEdited.clear();

    form.syncFieldsFromDraft();
    map.resetForNewRecord(keptBuildingLabel: keptBuilding);

    errors = const {};
    showErrorBar = false;
    saved = false;
    savedName = '';
    notifyListeners();
  }

  Future<void> _loadStoredDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(draftKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final payload = Map<String, dynamic>.from(decoded['draft'] as Map);
      final savedAt = DateTime.tryParse(decoded['savedAt'] as String? ?? '');
      final name = (payload['name'] as String? ?? '').trim();
      _storedDraft = payload;
      _storedDraftAt = savedAt;
      draftFound = true;
      draftAge = _relative(savedAt);
      draftPreviewName = name.isEmpty ? 'Untitled facility' : name;
      notifyListeners();
    } catch (_) {}
  }

  static String _relative(DateTime? at) {
    if (at == null) return 'an earlier session';
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'moments ago';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) {
      return '${d.inHours} hour${d.inHours == 1 ? '' : 's'} ago';
    }
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }

  void restoreDraft() {
    final payload = _storedDraft;
    if (payload == null) return;
    final restored = FacilityDraft.fromJson(payload);

    draft
      ..name = restored.name
      ..category = restored.category
      ..description = restored.description
      ..capacity = restored.capacity
      ..status = restored.status
      ..campusName = restored.campusName
      ..building = restored.building
      ..floor = restored.floor
      ..room = restored.room
      ..geoBuilding = restored.geoBuilding
      ..street = restored.street
      ..barangay = restored.barangay
      ..municipality = restored.municipality
      ..province = restored.province
      ..region = restored.region
      ..country = restored.country
      ..pin = restored.pin
      ..accuracy = restored.accuracy
      ..confirmedOutside = restored.confirmedOutside
      ..requiresApproval = restored.requiresApproval
      ..maintenance = restored.maintenance
      ..publicListing = restored.publicListing
      ..days = List<bool>.from(restored.days)
      ..openTime = restored.openTime
      ..closeTime = restored.closeTime
      ..maxDuration = restored.maxDuration
      ..advance = restored.advance
      ..buffer = restored.buffer;

    draft.geoEdited
      ..clear()
      ..addAll(restored.geoEdited);
    draft.amenities
      ..clear()
      ..addAll(restored.amenities);
    final droppedPhotos = (payload['photos'] as List?)?.length ?? 0;
    draft.photos
      ..clear()
      ..addAll(restored.photos);

    form.syncFieldsFromDraft();
    draftSavedAt = _storedDraftAt;
    draftFound = false;
    map.hydrateFromRestoredDraft();
    notifyListeners();

    final lost = droppedPhotos - draft.photos.length;
    showToast(
      ToastMessage(
        lost > 0
            ? 'Draft restored. $lost photo${lost == 1 ? '' : 's'} could not be '
                  're-read from disk and were dropped.'
            : 'Draft restored.',
        tone: lost > 0 ? AdvisoryTone.warn : AdvisoryTone.good,
      ),
    );
  }

  Future<void> dropStoredDraft() async {
    draftFound = false;
    notifyListeners();
    await _clearStoredDraft();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 1500), _writeDraft);
  }

  Future<void> _writeDraft() async {
    if (!draft.isDirty || saved) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setString(
        draftKey,
        jsonEncode({'savedAt': now.toIso8601String(), 'draft': draft.toJson()}),
      );
      draftSavedAt = now;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> saveDraftNow() => _writeDraft();

  Future<void> _clearStoredDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(draftKey);
    } catch (_) {}
    draftSavedAt = null;
  }

  String? get draftChipLabel {
    if (draftSavedAt == null) return null;
    return 'Draft saved ${_relative(draftSavedAt)}';
  }

  bool get isDirty => draft.isDirty;
}
