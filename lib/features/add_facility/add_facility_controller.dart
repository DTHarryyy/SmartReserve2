import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/sr_toast_controller.dart';
import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/facility_draft.dart';
import '../../model/facility_photo.dart';
import '../../model/notice.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/geo.dart';
import 'facility_editor_focus.dart';
export '../../model/notice.dart' show AdvisoryTone, ToastMessage;

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

class AddFacilityController extends ChangeNotifier {
  AddFacilityController({required this.toasts}) {
    nameField.addListener(_syncName);
    capacityField.addListener(_syncCapacity);
    descriptionField.addListener(_syncDescription);
    roomField.addListener(_syncRoom);
    _loadStoredDraft();
  }

  final SrToastController toasts;

  final FacilityDraft draft = FacilityDraft();
  List<Facility> availableFacilities = const [];

  Map<RequiredItem, String> errors = const {};
  bool showErrorBar = false;
  bool saving = false;
  bool saved = false;
  String savedName = '';

  GeoState geoState = GeoState.idle;
  Timer? _geoTimer;

  MapTab tab = MapTab.map;
  MapLayer layer = MapLayer.street;
  bool showBoundary = true;
  bool showExistingPins = true;
  bool fullscreenMap = false;
  bool mapOffline = false;
  double zoom = 17;

  int pinDropCount = 0;
  FacilityEditorReason? qualityReason;

  String amenityQuery = '';
  bool amenityOpen = false;

  String searchQuery = '';
  bool searchOpen = false;

  bool draftFound = false;
  String draftAge = '';
  String draftPreviewName = '';
  Map<String, dynamic>? _storedDraft;
  DateTime? _storedDraftAt;
  DateTime? draftSavedAt;
  Timer? _autosaveTimer;

  final nameField = TextEditingController();
  final capacityField = TextEditingController();
  final descriptionField = TextEditingController();
  final roomField = TextEditingController();
  final amenityField = TextEditingController();

  final amenityFocus = FocusNode();
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

  final sectionKeys = {
    for (final item in RequiredItem.values) item: GlobalKey(),
  };
  final ScrollController formScroll = ScrollController();

  @override
  void dispose() {
    _geoTimer?.cancel();
    _autosaveTimer?.cancel();
    nameField.dispose();
    capacityField.dispose();
    descriptionField.dispose();
    roomField.dispose();
    amenityField.dispose();
    amenityFocus.dispose();
    searchField.dispose();
    for (final c in geoFields.values) {
      c.dispose();
    }
    formScroll.dispose();
    super.dispose();
  }

  void _syncName() => _edit(() => draft.name = nameField.text);
  void _syncCapacity() => _edit(() => draft.capacity = capacityField.text);
  void _syncDescription() =>
      _edit(() => draft.description = descriptionField.text);
  void _syncRoom() => _edit(() => draft.room = roomField.text);

  void _edit(VoidCallback change) {
    change();
    if (errors.isNotEmpty) {
      final fresh = draft.validate();
      errors = {
        for (final entry in errors.entries)
          if (fresh.containsKey(entry.key)) entry.key: fresh[entry.key]!,
      };
      if (errors.isEmpty) showErrorBar = false;
    }
    _scheduleAutosave();
    notifyListeners();
  }

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

    final b = buildingNamed(value);
    if (b != null && b.mapped && draft.pin == null) {
      centerOn(b.coords, zoom: 18);
    }
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

  LatLng? pendingCenter;
  double? pendingZoom;
  double? pendingZoomTo;

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
    pendingZoomTo = (zoom + delta).clamp(3, 21);
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

  void _resolveAddress(LatLng at) {
    _geoTimer?.cancel();
    geoState = GeoState.loading;
    notifyListeners();
    _geoTimer = Timer(const Duration(milliseconds: 650), () {
      final address = reverseGeocode(at).toMap();
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
      _scheduleAutosave();
      notifyListeners();
    });
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
      ? 'The pin marks the entrance, not the centre of the room.'
      : 'No map? Search a building, paste coordinates, or capture GPS.';

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

    if (qualityReason == FacilityEditorReason.outsideCampus ||
        draft.confirmedOutside) {
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
        for (final b in buildings.take(5))
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
    for (final b in buildings) {
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
      _edit(() => draft.building = hit.building!);
    }
    centerOn(hit.target, zoom: 18.5);
    notifyListeners();
  }

  void submitSearch() {
    final hits = searchResults;
    if (hits.isNotEmpty) pickSearchHit(hits.first);
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

  final _picker = ImagePicker();
  bool dragging = false;

  static const maxPhotos = 8;

  void setDragging(bool value) {
    if (dragging == value) return;
    dragging = value;
    notifyListeners();
  }

  bool get photosFull => draft.photos.length >= maxPhotos;

  void addPlaceholderPhoto() {
    if (_rejectIfFull()) return;
    _edit(
      () => draft.photos.add(FacilityPhoto.placeholder(draft.photos.length)),
    );
  }

  bool _rejectIfFull() {
    if (!photosFull) return false;
    showToast(
      const ToastMessage(
        'That is the $maxPhotos-photo limit. Remove one to add another.',
        tone: AdvisoryTone.warn,
      ),
    );
    return true;
  }

  Future<void> pickFiles() async {
    if (_rejectIfFull()) return;
    try {
      final picked = await _picker.pickMultiImage();
      await _ingest(picked);
    } catch (e) {
      showToast(
        const ToastMessage(
          'No image picker is available on this platform. Use "Add '
          'placeholder" while testing.',
          tone: AdvisoryTone.warn,
        ),
      );
    }
  }

  Future<void> pickCamera() async {
    if (_rejectIfFull()) return;
    try {
      final shot = await _picker.pickImage(source: ImageSource.camera);
      if (shot != null) await _ingest([shot]);
    } catch (e) {
      showToast(
        const ToastMessage(
          'No camera is available on this device.',
          tone: AdvisoryTone.warn,
        ),
      );
    }
  }

  Future<void> addFiles(List<XFile> files) => _ingest(files);

  Future<void> _ingest(List<XFile> picked) async {
    if (picked.isEmpty) return;
    final photos = <FacilityPhoto>[];
    for (final file in picked) {
      if (draft.photos.length + photos.length >= maxPhotos) break;
      final lower = file.name.toLowerCase();
      if (!lower.endsWith('.jpg') &&
          !lower.endsWith('.jpeg') &&
          !lower.endsWith('.png')) {
        showToast(
          ToastMessage(
            '${file.name} is not a JPG or PNG.',
            tone: AdvisoryTone.warn,
          ),
        );
        continue;
      }
      if (await file.length() > 10 * 1024 * 1024) {
        showToast(
          ToastMessage(
            '${file.name} is larger than 10 MB.',
            tone: AdvisoryTone.warn,
          ),
        );
        continue;
      }
      photos.add(
        FacilityPhoto(
          id: '${file.path}-${DateTime.now().microsecondsSinceEpoch}',

          path: kIsWeb ? null : file.path,
          bytes: kIsWeb ? await file.readAsBytes() : null,
          label: file.name,
        ),
      );
    }
    if (photos.isEmpty) return;
    _edit(() => draft.photos.addAll(photos));
  }

  void removePhoto(String id) =>
      _edit(() => draft.photos.removeWhere((p) => p.id == id));

  void movePhoto(String id, int delta) {
    final index = draft.photos.indexWhere((p) => p.id == id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= draft.photos.length) return;
    _edit(() {
      final photo = draft.photos.removeAt(index);
      draft.photos.insert(target, photo);
    });
  }

  void makeCover(String id) {
    final index = draft.photos.indexWhere((p) => p.id == id);
    if (index <= 0) return;
    _edit(() {
      final photo = draft.photos.removeAt(index);
      draft.photos.insert(0, photo);
    });
    showToast(const ToastMessage('Cover photo updated.'));
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

  int tileGeneration = 0;

  void retryMap() {
    mapOffline = false;
    tileGeneration++;
    notifyListeners();
    showToast(
      const ToastMessage('Retrying the tile server…', tone: AdvisoryTone.info),
    );
  }

  void showToast(ToastMessage message, {Duration? duration}) =>
      toasts.show(message, duration: duration);

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

  String? editingId;

  void startNewRecord() {
    editingId = null;
    qualityReason = null;
    saved = false;
    savedName = '';
    _resetFields(keepBuilding: false);
  }

  void loadForEditing(Facility facility, {FacilityEditorReason? reason}) {
    editingId = facility.id;
    qualityReason = reason;
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

    nameField.text = draft.name;
    capacityField.text = draft.capacity;
    descriptionField.text = draft.description;
    roomField.text = draft.room;
    geoFields['geoBuilding']!.text = draft.geoBuilding;
    geoFields['street']!.text = draft.street;
    geoFields['barangay']!.text = draft.barangay;
    geoFields['municipality']!.text = draft.municipality;
    geoFields['province']!.text = draft.province;
    geoFields['region']!.text = draft.region;
    geoFields['country']!.text = draft.country;

    if (draft.pin != null) {
      geoState = GeoState.ready;
      _resolveAddress(draft.pin!);
      centerOn(draft.pin!, zoom: 18.5);
    } else {
      geoState = GeoState.idle;
      for (final c in geoFields.values) {
        c.clear();
      }
      final b = buildingNamed(facility.building);
      if (b != null && b.mapped) centerOn(b.coords, zoom: 18);
    }
    notifyListeners();
  }

  void focusEditorSection(
    FacilityEditorFocus? focus, {
    FacilityEditorReason? reason,
  }) {
    if (focus == null) return;
    qualityReason = reason ?? qualityReason;
    final item = switch (focus) {
      FacilityEditorFocus.location ||
      FacilityEditorFocus.locationAccuracy => RequiredItem.pin,
      FacilityEditorFocus.photos => RequiredItem.photos,
    };
    if (focus != FacilityEditorFocus.photos) tab = MapTab.map;
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
    notifyListeners();
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
    qualityReason = null;
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

    nameField.clear();
    capacityField.clear();
    descriptionField.clear();
    roomField.clear();
    for (final c in geoFields.values) {
      c.clear();
    }

    errors = const {};
    showErrorBar = false;
    saved = false;
    savedName = '';
    geoState = GeoState.idle;
    tab = MapTab.map;
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

    nameField.text = draft.name;
    capacityField.text = draft.capacity;
    descriptionField.text = draft.description;
    roomField.text = draft.room;
    geoFields['geoBuilding']!.text = draft.geoBuilding;
    geoFields['street']!.text = draft.street;
    geoFields['barangay']!.text = draft.barangay;
    geoFields['municipality']!.text = draft.municipality;
    geoFields['province']!.text = draft.province;
    geoFields['region']!.text = draft.region;
    geoFields['country']!.text = draft.country;

    geoState = draft.pin == null ? GeoState.idle : GeoState.ready;
    draftFound = false;
    draftSavedAt = _storedDraftAt;
    if (draft.pin != null) centerOn(draft.pin!, zoom: 18.5);
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
