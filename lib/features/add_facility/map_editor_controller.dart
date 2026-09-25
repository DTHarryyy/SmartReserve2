import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/sr_toast_controller.dart';
import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/facility_draft.dart';
import '../../model/notice.dart';
import '../../theme/sr_theme.dart';
import '../../util/geo.dart';
import 'facility_editor_focus.dart';
import 'safe_change_notifier.dart';

/// The facility editor only needs a campus-level view. This prevents a zoomed
/// out browser map from loading a large number of tiles at once.
const campusMinimumZoom = 14.0;
const campusMaximumZoom = 19.0;
const campusBuildingOverridesKey = 'smartreserve.campus_buildings.v1';

enum MapTab { map, preview }

enum MapLayer {
  street('Street', 'OpenStreetMap standard'),
  satellite('Satellite', 'Aerial imagery for rooftop confirmation'),
  light('Light', 'Muted base map — easiest to read pins against');

  const MapLayer(this.label, this.title);

  final String label;
  final String title;
}

enum GeoState { idle, loading, ready }

class MapAdvisory {
  const MapAdvisory({
    required this.tone,
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const [],
  });

  final AdvisoryTone tone;
  final IconData icon;
  final String title;
  final String body;
  final List<AdvisoryAction> actions;

  Color background(BuildContext context) => switch (tone) {
    AdvisoryTone.good => context.srColors.greenTint,
    AdvisoryTone.info => context.srColors.primaryTint,
    AdvisoryTone.warn => context.srColors.amberTint,
    AdvisoryTone.block => context.srColors.redTint,
  };

  Color borderColor(BuildContext context) => switch (tone) {
    AdvisoryTone.good => context.srColors.greenLine,
    AdvisoryTone.info => context.srColors.primaryLine,
    AdvisoryTone.warn => context.srColors.amberLine,
    AdvisoryTone.block => context.srColors.redLine,
  };

  Color foreground(BuildContext context) => switch (tone) {
    AdvisoryTone.good => context.srColors.greenDark,
    AdvisoryTone.info => context.srColors.primaryDeep,
    AdvisoryTone.warn => context.srColors.amber,
    AdvisoryTone.block => context.srColors.red,
  };

  Color iconBackground(BuildContext context) => switch (tone) {
    AdvisoryTone.good => context.srColors.greenTint,
    AdvisoryTone.info => context.srColors.primaryTint,
    AdvisoryTone.warn => context.srColors.amberIcon,
    AdvisoryTone.block => context.srColors.redTint,
  };

  Color bodyForeground(BuildContext context) => switch (tone) {
    AdvisoryTone.warn => context.srColors.amberInk,
    AdvisoryTone.block => context.srColors.ink3,
    _ => context.srColors.ink4,
  };
}

class AdvisoryAction {
  const AdvisoryAction(this.label, this.onPressed, {this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;
}

class SearchHit {
  const SearchHit({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.kind,
    required this.target,
    this.building,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String kind;
  final LatLng target;

  final String? building;
}

/// Owns everything map/pin/zoom/camera/search/geocoding related for the
/// Add Facility editor. Kept as its own [ChangeNotifier] so widgets that
/// only care about map state (the [CampusMap] tree in particular) never
/// have to listen to form/photos/amenities edits.
class MapEditorController extends ChangeNotifier with SafeChangeNotifier {
  MapEditorController({
    required this.draft,
    required this._toasts,
    required this.onBuildingResolvedFromMap,
    required this.onFacilityNameEdited,
    required this.onFieldEdited,
  }) {
    unawaited(_loadBuildingOverrides());
  }

  final FacilityDraft draft;
  final SrToastController _toasts;

  /// Bridge: user picked a building from map search and the form's
  /// building field was empty.
  final ValueChanged<String> onBuildingResolvedFromMap;

  /// Bridge: the inline label editor on the map updates the canonical form
  /// field, which in turn keeps validation and autosave behavior unchanged.
  final ValueChanged<String> onFacilityNameEdited;

  /// Bridge: notify the coordinator that a field changed, so it can
  /// revalidate and schedule an autosave.
  final VoidCallback onFieldEdited;

  MapTab tab = MapTab.map;
  MapLayer layer = MapLayer.street;
  bool showBoundary = true;
  bool showExistingPins = true;
  bool fullscreenMap = false;
  bool mapOffline = false;
  double zoom = 17;

  int pinDropCount = 0;
  FacilityEditorReason? qualityReason;

  GeoState geoState = GeoState.idle;
  Timer? _geoTimer;

  String searchQuery = '';
  bool searchOpen = false;
  final searchField = TextEditingController();
  final Map<String, TextEditingController> geoFields = {
    for (final k in const [
      'geoBuilding',
      'street',
      'barangay',
      'municipality',
      'province',
      'region',
      'country',
    ])
      k: TextEditingController(),
  };

  LatLng? pendingCenter;
  double? pendingZoom;
  double? pendingZoomTo;

  int tileGeneration = 0;

  List<Facility> availableFacilities = const [];
  final List<CampusBuilding> editableBuildings = List.of(buildings);
  int? editingBuildingIndex;

  /// Mirror of [FacilityDraft.building], kept in sync by every path that
  /// can change it, so the map's building-chip highlight never needs to
  /// listen to the form slice just for this one string.
  String selectedBuildingLabel = '';
  String facilityLabel = '';

  @override
  void dispose() {
    _geoTimer?.cancel();
    searchField.dispose();
    for (final c in geoFields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _edit(VoidCallback change) {
    change();
    notifyListeners();
    onFieldEdited();
  }

  void setSelectedBuildingLabel(String value) {
    selectedBuildingLabel = value;
    notifyListeners();
  }

  CampusBuilding? buildingNamed(String name) {
    for (var index = 0; index < editableBuildings.length; index++) {
      final building = editableBuildings[index];
      if (building.name == name ||
          (index < buildings.length && buildings[index].name == name)) {
        return building;
      }
    }
    return null;
  }

  String canonicalBuildingName(String name) =>
      buildingNamed(name)?.name ?? name;

  bool isEditingBuilding(int index) => editingBuildingIndex == index;

  String? buildingNameError(int index, String value) {
    final clean = value.trim();
    if (clean.isEmpty) return 'Enter a building name.';
    if (clean.length > 80) return 'Use 80 characters or fewer.';
    final duplicate = editableBuildings.indexed.any(
      (entry) =>
          entry.$1 != index &&
          entry.$2.name.toLowerCase() == clean.toLowerCase(),
    );
    return duplicate ? 'That building name is already in use.' : null;
  }

  void editBuilding(int index, String name) {
    final error = buildingNameError(index, name);
    if (error != null || index < 0 || index >= editableBuildings.length) {
      return;
    }
    final previous = editableBuildings[index];
    final clean = name.trim();
    editableBuildings[index] = CampusBuilding(
      clean,
      previous.coords,
      mapped: previous.mapped,
    );
    editingBuildingIndex = index;
    if (draft.building == previous.name) {
      onBuildingResolvedFromMap(clean);
      selectedBuildingLabel = clean;
    }
    notifyListeners();
    unawaited(_saveBuildingOverrides());
    showToast(
      ToastMessage('Editing $clean. Drag its label to move the building pin.'),
    );
  }

  void dragBuildingTo(int index, LatLng to) {
    if (editingBuildingIndex != index ||
        index < 0 ||
        index >= editableBuildings.length) {
      return;
    }
    final building = editableBuildings[index];
    editableBuildings[index] = CampusBuilding(building.name, to, mapped: true);
    notifyListeners();
  }

  void endBuildingDrag(int index) {
    if (editingBuildingIndex != index ||
        index < 0 ||
        index >= editableBuildings.length) {
      return;
    }
    unawaited(_saveBuildingOverrides());
    final building = editableBuildings[index];
    showToast(
      ToastMessage(
        '${building.name} moved to ${formatCoords(building.coords)}.',
      ),
    );
  }

  void finishBuildingEdit() {
    if (editingBuildingIndex == null) return;
    editingBuildingIndex = null;
    notifyListeners();
  }

  Future<void> _loadBuildingOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(campusBuildingOverridesKey);
      if (raw == null) return;
      final rows = jsonDecode(raw) as List<dynamic>;
      for (
        var index = 0;
        index < rows.length && index < editableBuildings.length;
        index++
      ) {
        final row = Map<String, dynamic>.from(rows[index] as Map);
        final name = '${row['name'] ?? ''}'.trim();
        final latitude = (row['latitude'] as num?)?.toDouble();
        final longitude = (row['longitude'] as num?)?.toDouble();
        if (name.isEmpty || latitude == null || longitude == null) continue;
        editableBuildings[index] = CampusBuilding(
          name,
          LatLng(latitude, longitude),
          mapped: row['mapped'] as bool? ?? true,
        );
      }
      final canonical = canonicalBuildingName(draft.building);
      if (canonical.isNotEmpty && canonical != draft.building) {
        onBuildingResolvedFromMap(canonical);
        selectedBuildingLabel = canonical;
      }
      notifyListeners();
    } catch (_) {
      // Corrupt local overrides should never prevent the editor from opening.
    }
  }

  Future<void> _saveBuildingOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        campusBuildingOverridesKey,
        jsonEncode([
          for (final building in editableBuildings)
            {
              'name': building.name,
              'latitude': building.coords.latitude,
              'longitude': building.coords.longitude,
              'mapped': building.mapped,
            },
        ]),
      );
    } catch (_) {}
  }

  void setFacilityLabel(String value) {
    if (facilityLabel == value) return;
    facilityLabel = value;
    notifyListeners();
  }

  void renameFacilityFromMap(String value) {
    final clean = value.trim();
    if (clean.isEmpty || clean == draft.name) return;
    onFacilityNameEdited(clean);
  }

  void setQualityReason(FacilityEditorReason? reason) {
    qualityReason = reason;
    notifyListeners();
  }

  void editGeoField(String key, String value) => _edit(() {
    draft.geoEdited.add(key);
    switch (key) {
      case 'geoBuilding':
        draft.geoBuilding = value;
      case 'street':
        draft.street = value;
      case 'barangay':
        draft.barangay = value;
      case 'municipality':
        draft.municipality = value;
      case 'province':
        draft.province = value;
      case 'region':
        draft.region = value;
      case 'country':
        draft.country = value;
    }
  });

  void centerOn(LatLng target, {double? zoom}) {
    pendingCenter = target;
    pendingZoom = zoom;
    notifyListeners();
  }

  void consumeCameraRequest() {
    pendingCenter = null;
    pendingZoom = null;
    pendingZoomTo = null;
  }

  void zoomBy(double delta) {
    pendingZoomTo = (zoom + delta).clamp(campusMinimumZoom, campusMaximumZoom);
    notifyListeners();
  }

  void syncZoom(double value) => zoom = value;

  void dropPin(LatLng at, {bool announce = true}) {
    final isFirst = draft.pin == null;
    qualityReason = null;
    _edit(() {
      draft.pin = at;
      draft.accuracy = accuracyForZoom(zoom);
      draft.confirmedOutside = false;
    });
    pinDropCount++;
    _resolveAddress(at);
    if (announce && isFirst) {
      showToast(const ToastMessage('Pin dropped. Address is resolving…'));
    }
  }

  void movePin(LatLng to) {
    if (draft.pin == null) return;
    qualityReason = null;
    _edit(() {
      draft.pin = to;
      draft.accuracy = accuracyForZoom(zoom);
      draft.confirmedOutside = false;
    });
    _resolveAddress(to);
  }

  /// Called on every raw pointer-move frame while dragging the pin.
  /// Intentionally bypasses [_edit]/[onFieldEdited] so a drag never
  /// triggers revalidation or autosave scheduling — only [endPinDrag]
  /// (once per gesture) does that.
  void dragPinTo(LatLng to) {
    if (draft.pin == null) return;
    qualityReason = null;
    draft.pin = to;
    draft.confirmedOutside = false;
    notifyListeners();
  }

  void endPinDrag() {
    final pin = draft.pin;
    if (pin == null) return;
    qualityReason = null;
    _edit(() => draft.accuracy = accuracyForZoom(zoom));
    _resolveAddress(pin);
  }

  void nudgePin({double north = 0, double east = 0}) {
    final pin = draft.pin;
    if (pin == null) return;
    qualityReason = null;
    final next = nudge(pin, north: north, east: east);
    _edit(() {
      draft.pin = next;

      draft.accuracy = (draft.accuracy ?? accuracyForZoom(zoom)).clamp(2, 40);
    });
    _resolveAddress(next);
    centerOn(next);
  }

  void clearPin() {
    _geoTimer?.cancel();
    qualityReason = null;
    _edit(() {
      draft.pin = null;
      draft.accuracy = null;
      draft.confirmedOutside = false;
      for (final key in draft.geoEdited.toList()) {
        draft.geoEdited.remove(key);
      }
      draft.geoBuilding = '';
      draft.street = '';
      draft.barangay = '';
      draft.municipality = '';
      draft.province = '';
      draft.region = '';
      draft.country = '';
      for (final c in geoFields.values) {
        c.text = '';
      }
    });
    geoState = GeoState.idle;
    showToast(const ToastMessage('Pin removed.', tone: AdvisoryTone.info));
  }

  void snapToBuilding() {
    final b = buildingNamed(draft.building);
    if (b == null || !b.mapped) return;
    zoom = 18;
    dropPin(b.coords, announce: false);
    centerOn(b.coords, zoom: 18);
    showToast(ToastMessage('Pin snapped to ${b.name}.'));
  }

  void confirmOutsideBoundary() {
    qualityReason = null;
    _edit(() => draft.confirmedOutside = true);
    showToast(
      const ToastMessage(
        'Out-of-boundary pin kept. It will be flagged for review.',
        tone: AdvisoryTone.info,
      ),
    );
  }

  Future<void> useGps() async {
    qualityReason = null;
    showToast(
      const ToastMessage('Reading GPS…', tone: AdvisoryTone.info),
      duration: const Duration(seconds: 8),
    );
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        showToast(
          const ToastMessage(
            'Location services are switched off. Pin it on the map instead.',
            tone: AdvisoryTone.warn,
          ),
        );
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        showToast(
          const ToastMessage(
            'Location permission denied. Pin it on the map instead.',
            tone: AdvisoryTone.warn,
          ),
        );
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final at = LatLng(position.latitude, position.longitude);
      _edit(() {
        draft.pin = at;
        draft.accuracy = position.accuracy.round().clamp(2, 999);
        draft.confirmedOutside = false;
      });
      pinDropCount++;
      _resolveAddress(at);
      centerOn(at, zoom: 19);
      showToast(
        ToastMessage(
          'Pinned from GPS at ±${draft.accuracy} m. Nudge it onto the doorway.',
        ),
      );
    } catch (e) {
      showToast(
        const ToastMessage(
          'GPS did not answer in time. Pin it on the map instead.',
          tone: AdvisoryTone.warn,
        ),
      );
    }
  }

  /// Public wrapper so the coordinator's hydration methods can trigger a
  /// re-geocode without reaching into a private member across files.
  void resolveAddress(LatLng at) => _resolveAddress(at);

  void _resolveAddress(LatLng at) {
    _geoTimer?.cancel();
    geoState = GeoState.loading;
    notifyListeners();
    _geoTimer = Timer(const Duration(milliseconds: 650), () {
      final address = reverseGeocode(at).toMap();
      final nearest = _nearestEditableBuilding(at);
      if (nearest != null && nearest.metres <= buildingProximityLimit) {
        address['geoBuilding'] = nearest.building.name;
      }
      address.forEach((key, value) {
        if (draft.geoEdited.contains(key)) return;
        geoFields[key]!.text = value;
        switch (key) {
          case 'geoBuilding':
            draft.geoBuilding = value;
          case 'street':
            draft.street = value;
          case 'barangay':
            draft.barangay = value;
          case 'municipality':
            draft.municipality = value;
          case 'province':
            draft.province = value;
          case 'region':
            draft.region = value;
          case 'country':
            draft.country = value;
        }
      });
      geoState = GeoState.ready;
      notifyListeners();
      onFieldEdited();
    });
  }

  ({CampusBuilding building, double metres})? _nearestEditableBuilding(
    LatLng at,
  ) {
    CampusBuilding? nearest;
    var distance = double.infinity;
    for (final building in editableBuildings) {
      if (!building.mapped) continue;
      final candidate = haversine(at, building.coords);
      if (candidate < distance) {
        nearest = building;
        distance = candidate;
      }
    }
    return nearest == null ? null : (building: nearest, metres: distance);
  }

  bool get hasPin => draft.pin != null;

  bool get insideBoundary =>
      draft.pin != null && inPolygon(draft.pin!, campus.boundary);

  double? get metresFromCenter =>
      draft.pin == null ? null : haversine(draft.pin!, campus.center);

  ({CampusBuilding building, double metres})? get buildingCheck {
    final pin = draft.pin;
    final b = buildingNamed(draft.building);
    if (pin == null || b == null || !b.mapped) return null;
    return (building: b, metres: haversine(pin, b.coords));
  }

  bool get tooFarFromBuilding {
    final check = buildingCheck;
    return check != null && check.metres > buildingProximityLimit;
  }

  String get coordLabel =>
      draft.pin == null ? 'No pin yet' : formatCoords(draft.pin!);

  (String label, Color background, Color foreground) pinBadge(
    BuildContext context,
  ) {
    final colors = context.srColors;
    if (!hasPin) return ('NO PIN', colors.dividerSoft, colors.muted);
    if (!insideBoundary && !draft.confirmedOutside) {
      return ('OUTSIDE', colors.redTint, colors.red);
    }
    if (tooFarFromBuilding) {
      return ('CHECK', colors.amberTint, colors.amber);
    }
    if ((draft.accuracy ?? 99) > accuracyWarnLimit) {
      return ('COARSE', colors.amberTint, colors.amber);
    }
    return ('PINNED', colors.greenTint, colors.greenDark);
  }

  String get mapHint => hasPin
      ? 'Drag the pin, or nudge it in 1 m steps until it sits on the doorway.'
      : 'Click anywhere on the map to drop the pin.';

  String get footerHint => hasPin
      ? 'The pin marks the entrance. Right-click a building label to rename '
            'or move its reference pin.'
      : 'Search or drop a facility pin. Right-click a building label to '
            'rename or move its reference pin.';

  List<({String key, String value, Color color})> liveStats(
    BuildContext context,
  ) {
    final pin = draft.pin;
    if (pin == null) return const [];
    final colors = context.srColors;
    final accuracy = draft.accuracy ?? 0;
    return [
      (key: 'LATITUDE', value: formatLat(pin.latitude), color: colors.ink),
      (key: 'LONGITUDE', value: formatLat(pin.longitude), color: colors.ink),
      (
        key: 'ACCURACY',
        value: '±$accuracy m',
        color: accuracy > accuracyWarnLimit ? colors.amber : colors.greenDark,
      ),
      (
        key: 'FROM CENTRE',
        value: formatMetres(metresFromCenter ?? 0),
        color: insideBoundary ? colors.ink : colors.red,
      ),
    ];
  }

  MapAdvisory? get advisory {
    final pin = draft.pin;
    if (pin == null) {
      if (qualityReason == FacilityEditorReason.missingPin) {
        return const MapAdvisory(
          tone: AdvisoryTone.block,
          icon: Icons.add_location_alt_rounded,
          title: 'Map pin is missing',
          body:
              'Place a pin for this facility so students can open reliable walking directions.',
        );
      }
      return null;
    }

    if (!insideBoundary && !draft.confirmedOutside) {
      final d = formatMetres(metresFromCenter ?? 0);
      return MapAdvisory(
        tone: AdvisoryTone.warn,
        icon: Icons.warning_amber_rounded,
        title: 'Pin sits outside the campus boundary',
        body:
            'It is $d from the campus centre. Saving is still allowed — '
            'boundaries drift and annexes exist before the GIS layer catches '
            'up — but the facility will be flagged for review.',
        actions: [
          AdvisoryAction('Keep it anyway', confirmOutsideBoundary),
          AdvisoryAction(
            'Back to campus',
            () => centerOn(campus.center, zoom: 17),
          ),
        ],
      );
    }

    if (!insideBoundary &&
        (qualityReason == FacilityEditorReason.outsideCampus ||
            draft.confirmedOutside)) {
      return MapAdvisory(
        tone: AdvisoryTone.warn,
        icon: Icons.flag_outlined,
        title: draft.confirmedOutside
            ? 'Out-of-boundary pin confirmed'
            : 'Pin needs a boundary review',
        body:
            'This record is marked for review because the pin was saved outside the normal campus boundary. Move it inside the mapped campus, or keep it only when the location is intentionally outside.',
      );
    }

    if (qualityReason == FacilityEditorReason.unverifiedPin) {
      return const MapAdvisory(
        tone: AdvisoryTone.info,
        icon: Icons.fact_check_outlined,
        title: 'Existing pin needs confirmation',
        body:
            'The pin already exists, but it has not been verified by an administrator. Confirm it if the marker is correct, or move it deliberately if it is wrong.',
      );
    }

    if (qualityReason == FacilityEditorReason.lowCoordinateAccuracy) {
      return MapAdvisory(
        tone: AdvisoryTone.info,
        icon: Icons.adjust_rounded,
        title: 'Improve pin precision',
        body:
            'The current precision is +/-${draft.accuracy} m. Zoom in and re-drop, drag, or nudge the pin until the target precision is ${accuracyWarnLimit.round()} m or better.',
      );
    }

    final check = buildingCheck;
    if (check != null && check.metres > buildingProximityLimit) {
      final direction = compassFrom(check.building.coords, pin);
      return MapAdvisory(
        tone: AdvisoryTone.warn,
        icon: Icons.gps_not_fixed_rounded,
        title:
            'Pin is ${formatMetres(check.metres)} $direction of '
            '${check.building.name}',
        body:
            'Facilities usually sit within '
            '${buildingProximityLimit.round()} m of their building. Snap it, '
            'or keep it if this room is in an annex.',
        actions: [
          AdvisoryAction('Snap to building', snapToBuilding, primary: true),
        ],
      );
    }

    if ((draft.accuracy ?? 0) > accuracyWarnLimit) {
      return MapAdvisory(
        tone: AdvisoryTone.info,
        icon: Icons.adjust_rounded,
        title: 'Pin precision is ±${draft.accuracy} m',
        body:
            'Zoom in and re-drop, or nudge the pin, to claim a tighter '
            'figure. Students see this as the walking target.',
      );
    }

    final where = check == null
        ? 'inside the campus boundary'
        : '${formatMetres(check.metres)} from ${check.building.name}';
    return MapAdvisory(
      tone: AdvisoryTone.good,
      icon: Icons.check_rounded,
      title: 'Location checks passed',
      body: 'The pin is $where, at ±${draft.accuracy} m.',
    );
  }

  List<SearchHit> get searchResults {
    final q = searchQuery.trim().toLowerCase();

    final coords = parseCoords(searchQuery);
    if (coords != null) {
      return [
        SearchHit(
          icon: Icons.gps_not_fixed_rounded,
          title: formatCoords(coords),
          subtitle: inPolygon(coords, campus.boundary)
              ? 'Inside the campus boundary'
              : '${formatMetres(haversine(coords, campus.center))} from the '
                    'campus centre',
          kind: 'COORDS',
          target: coords,
        ),
      ];
    }
    if (q.isEmpty) {
      return [
        for (final b in editableBuildings.take(5))
          SearchHit(
            icon: Icons.apartment_rounded,
            title: b.name,
            subtitle: b.mapped ? formatCoords(b.coords) : 'Not mapped yet',
            kind: 'BUILDING',
            target: b.coords,
            building: b.name,
          ),
      ];
    }

    final hits = <SearchHit>[];
    for (final b in editableBuildings) {
      if (b.name.toLowerCase().contains(q)) {
        hits.add(
          SearchHit(
            icon: Icons.apartment_rounded,
            title: b.name,
            subtitle: b.mapped ? formatCoords(b.coords) : 'Not mapped yet',
            kind: 'BUILDING',
            target: b.coords,
            building: b.name,
          ),
        );
      }
    }
    for (final f in availableFacilities) {
      if (f.coords == null) continue;
      if (f.name.toLowerCase().contains(q) ||
          f.room.toLowerCase().contains(q)) {
        hits.add(
          SearchHit(
            icon: Icons.meeting_room_outlined,
            title: f.name,
            subtitle: '${f.room} · ${f.building}',
            kind: 'FACILITY',
            target: f.coords!,
            building: f.building,
          ),
        );
      }
    }
    for (final barangay in barangays) {
      if (barangay.toLowerCase().contains(q)) {
        hits.add(
          SearchHit(
            icon: Icons.place_outlined,
            title: 'Barangay $barangay',
            subtitle: 'Aparri, Cagayan',
            kind: 'ADDRESS',
            target: campus.center,
          ),
        );
      }
    }
    return hits;
  }

  bool get searchNoResults =>
      searchQuery.trim().isNotEmpty && searchResults.isEmpty;

  void setSearchQuery(String value) {
    searchQuery = value;
    searchOpen = true;
    notifyListeners();
  }

  void openSearch() {
    searchOpen = true;
    notifyListeners();
  }

  void closeSearch() {
    searchOpen = false;
    notifyListeners();
  }

  void pickSearchHit(SearchHit hit) {
    searchOpen = false;
    searchQuery = '';
    searchField.clear();
    if (hit.kind == 'COORDS') {
      zoom = 19;
      dropPin(hit.target, announce: false);
      centerOn(hit.target, zoom: 19);
      showToast(const ToastMessage('Pin placed at the pasted coordinates.'));
      return;
    }
    if (hit.building != null && draft.building.isEmpty) {
      onBuildingResolvedFromMap(hit.building!);
      setSelectedBuildingLabel(hit.building!);
    }
    centerOn(hit.target, zoom: 18.5);
    notifyListeners();
  }

  void submitSearch() {
    final hits = searchResults;
    if (hits.isNotEmpty) pickSearchHit(hits.first);
  }

  void setTab(MapTab value) {
    tab = value;
    notifyListeners();
  }

  void setLayer(MapLayer value) {
    layer = value;
    notifyListeners();
  }

  void toggleBoundary() {
    showBoundary = !showBoundary;
    notifyListeners();
  }

  void toggleExistingPins() {
    showExistingPins = !showExistingPins;
    notifyListeners();
  }

  void setFullscreenMap(bool value) {
    fullscreenMap = value;
    notifyListeners();
  }

  void setMapOffline(bool value) {
    if (mapOffline == value) return;
    mapOffline = value;
    notifyListeners();
  }

  void retryMap() {
    mapOffline = false;
    tileGeneration++;
    notifyListeners();
    showToast(
      const ToastMessage('Retrying the tile server…', tone: AdvisoryTone.info),
    );
  }

  /// Hydrates map-owned UI state after [FacilityDraft] fields were loaded
  /// from an existing [Facility] (see coordinator's `loadForEditing`).
  void hydrateForEditing() {
    final canonical = canonicalBuildingName(draft.building);
    if (canonical != draft.building) onBuildingResolvedFromMap(canonical);
    selectedBuildingLabel = canonical;
    facilityLabel = draft.name;
    geoFields['geoBuilding']!.text = draft.geoBuilding;
    geoFields['street']!.text = draft.street;
    geoFields['barangay']!.text = draft.barangay;
    geoFields['municipality']!.text = draft.municipality;
    geoFields['province']!.text = draft.province;
    geoFields['region']!.text = draft.region;
    geoFields['country']!.text = draft.country;
    if (draft.pin != null) {
      geoState = GeoState.ready;
      resolveAddress(draft.pin!);
      centerOn(draft.pin!, zoom: 18.5);
    } else {
      geoState = GeoState.idle;
      for (final c in geoFields.values) {
        c.clear();
      }
      final b = buildingNamed(draft.building);
      if (b != null && b.mapped) centerOn(b.coords, zoom: 18);
    }
    notifyListeners();
  }

  /// Hydrates map-owned UI state after a locally-stored draft was restored
  /// (geo text fields are already populated from the stored draft, so this
  /// never re-triggers a geocode).
  void hydrateFromRestoredDraft() {
    final canonical = canonicalBuildingName(draft.building);
    if (canonical != draft.building) onBuildingResolvedFromMap(canonical);
    selectedBuildingLabel = canonical;
    facilityLabel = draft.name;
    geoFields['geoBuilding']!.text = draft.geoBuilding;
    geoFields['street']!.text = draft.street;
    geoFields['barangay']!.text = draft.barangay;
    geoFields['municipality']!.text = draft.municipality;
    geoFields['province']!.text = draft.province;
    geoFields['region']!.text = draft.region;
    geoFields['country']!.text = draft.country;
    geoState = draft.pin == null ? GeoState.idle : GeoState.ready;
    if (draft.pin != null) centerOn(draft.pin!, zoom: 18.5);
    notifyListeners();
  }

  /// Resets map-owned UI state when starting a new/blank record.
  void resetForNewRecord({required String keptBuildingLabel}) {
    selectedBuildingLabel = keptBuildingLabel;
    facilityLabel = draft.name;
    for (final c in geoFields.values) {
      c.clear();
    }
    geoState = GeoState.idle;
    tab = MapTab.map;
    notifyListeners();
  }

  void showToast(ToastMessage message, {Duration? duration}) =>
      _toasts.show(message, duration: duration);
}
