import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../data/campus_data.dart';
import '../theme/sr_tokens.dart';
import 'facility.dart';
import 'facility_photo.dart';

enum FacilityStatus {
  active(
    'Active',
    SR.green,
    'Visible in the catalogue and open for reservations right away.',
  ),
  draft(
    'Draft',
    SR.muted,
    'Saved but unpublished. Only administrators can see it.',
  ),
  maintenance(
    'Maintenance',
    SR.orange,
    'Listed but closed for booking. Existing bookings are flagged for '
        'relocation.',
  );

  const FacilityStatus(this.label, this.dot, this.hint);

  final String label;
  final Color dot;
  final String hint;

  static FacilityStatus fromLabel(String label) => values.firstWhere(
    (s) => s.label == label,
    orElse: () => FacilityStatus.active,
  );
}

enum RequiredItem {
  name('Facility name', 1),
  category('Category', 2),
  capacity('Capacity', 3),
  building('Building', 4),
  pin('Map pin', 5),
  photos('Photos', 6);

  const RequiredItem(this.label, this.ordinal);

  final String label;
  final int ordinal;
}

class FacilityDraft {
  FacilityDraft();

  String name = '';
  String category = '';
  String description = '';
  String capacity = '';
  FacilityStatus status = FacilityStatus.active;

  String campusName = campus.name;
  String building = '';
  String floor = 'Ground floor';
  String room = '';

  String geoBuilding = '';
  String street = '';
  String barangay = '';
  String municipality = '';
  String province = '';
  String region = '';
  String country = '';

  final Set<String> geoEdited = <String>{};

  LatLng? pin;
  int? accuracy;

  bool confirmedOutside = false;

  final List<FacilityPhoto> photos = [];

  final List<String> amenities = [];

  bool requiresApproval = true;
  bool maintenance = false;
  bool publicListing = true;
  List<bool> days = [true, true, true, true, true, false, false];
  String openTime = '07:00';
  String closeTime = '19:00';
  String maxDuration = '4 hours';
  String advance = '30 days ahead';
  String buffer = '15 minutes';

  int? get capacitySeats {
    final n = int.tryParse(capacity.trim());
    return n != null && n > 0 ? n : null;
  }

  bool has(RequiredItem item) => switch (item) {
    RequiredItem.name => name.trim().isNotEmpty,
    RequiredItem.category => category.isNotEmpty,
    RequiredItem.capacity => capacitySeats != null,
    RequiredItem.building => building.isNotEmpty,
    RequiredItem.pin => pin != null,
    RequiredItem.photos => photos.isNotEmpty,
  };

  int get completeCount => RequiredItem.values.where(has).length;

  double get completeFraction => completeCount / RequiredItem.values.length;

  String get completePct => '${(completeFraction * 100).round()}%';

  String get whereLine {
    final parts = [
      if (building.isNotEmpty) building,
      if (floor.isNotEmpty) floor,
      if (room.trim().isNotEmpty) room.trim(),
    ];
    return parts.isEmpty ? 'Location not set' : parts.join(' · ');
  }

  String get hoursLine => '$openTime–$closeTime';

  String get daysLine {
    final on = [
      for (var i = 0; i < days.length; i++)
        if (days[i]) dayLabels[i],
    ];
    if (on.isEmpty) return 'No days selected';
    if (on.length == 7) return 'Mon–Sun';

    var contiguous = true;
    final first = days.indexOf(true);
    final last = days.lastIndexOf(true);
    for (var i = first; i <= last; i++) {
      if (!days[i]) contiguous = false;
    }
    return contiguous && on.length > 2
        ? '${dayLabels[first]}–${dayLabels[last]}'
        : on.join(', ');
  }

  Map<RequiredItem, String> validate({
    Iterable<Facility> facilities = const [],
    String? editingId,
  }) {
    final errors = <RequiredItem, String>{};

    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      errors[RequiredItem.name] = 'Give it the name people will search for.';
    } else if (trimmed.length < 3) {
      errors[RequiredItem.name] = 'Use the full name, not an abbreviation.';
    } else if (facilities.any(
      (f) => f.id != editingId && f.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      errors[RequiredItem.name] =
          'A facility called “$trimmed” already exists. Edit that one '
          'instead of creating a duplicate.';
    }

    if (category.isEmpty) {
      errors[RequiredItem.category] = 'Pick the category students filter by.';
    }

    final rawCapacity = capacity.trim();
    if (rawCapacity.isEmpty) {
      errors[RequiredItem.capacity] = 'Capacity is required.';
    } else if (int.tryParse(rawCapacity) == null) {
      errors[RequiredItem.capacity] = 'Enter a whole number of seats.';
    } else if (int.parse(rawCapacity) <= 0) {
      errors[RequiredItem.capacity] = 'Capacity has to be at least 1.';
    } else if (int.parse(rawCapacity) > 5000) {
      errors[RequiredItem.capacity] =
          'That looks too large. Check the seat count.';
    }

    if (building.isEmpty) {
      errors[RequiredItem.building] = 'Choose the building this room sits in.';
    }

    if (pin == null) {
      errors[RequiredItem.pin] =
          'Drop a pin on the map so students can walk to it.';
    }

    if (photos.isEmpty) {
      errors[RequiredItem.photos] =
          'Add at least one photo. The first becomes the cover.';
    }

    return errors;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'category': category,
    'description': description,
    'capacity': capacity,
    'status': status.label,
    'campus': campusName,
    'building': building,
    'floor': floor,
    'room': room,
    'geoBuilding': geoBuilding,
    'street': street,
    'barangay': barangay,
    'municipality': municipality,
    'province': province,
    'region': region,
    'country': country,
    'geoEdited': geoEdited.toList(),
    'lat': pin?.latitude,
    'lng': pin?.longitude,
    'accuracy': accuracy,
    'confirmedOutside': confirmedOutside,
    'photos': photos.map((p) => p.toJson()).toList(),
    'amenities': amenities,
    'requiresApproval': requiresApproval,
    'maintenance': maintenance,
    'publicListing': publicListing,
    'days': days,
    'openTime': openTime,
    'closeTime': closeTime,
    'maxDuration': maxDuration,
    'advance': advance,
    'buffer': buffer,
  };

  static FacilityDraft fromJson(Map<String, dynamic> json) {
    final d = FacilityDraft()
      ..name = json['name'] as String? ?? ''
      ..category = json['category'] as String? ?? ''
      ..description = json['description'] as String? ?? ''
      ..capacity = json['capacity'] as String? ?? ''
      ..status = FacilityStatus.fromLabel(json['status'] as String? ?? 'Active')
      ..campusName = json['campus'] as String? ?? campus.name
      ..building = json['building'] as String? ?? ''
      ..floor = json['floor'] as String? ?? 'Ground floor'
      ..room = json['room'] as String? ?? ''
      ..geoBuilding = json['geoBuilding'] as String? ?? ''
      ..street = json['street'] as String? ?? ''
      ..barangay = json['barangay'] as String? ?? ''
      ..municipality = json['municipality'] as String? ?? ''
      ..province = json['province'] as String? ?? ''
      ..region = json['region'] as String? ?? ''
      ..country = json['country'] as String? ?? ''
      ..accuracy = json['accuracy'] as int?
      ..confirmedOutside = json['confirmedOutside'] as bool? ?? false
      ..requiresApproval = json['requiresApproval'] as bool? ?? true
      ..maintenance = json['maintenance'] as bool? ?? false
      ..publicListing = json['publicListing'] as bool? ?? true
      ..openTime = json['openTime'] as String? ?? '07:00'
      ..closeTime = json['closeTime'] as String? ?? '19:00'
      ..maxDuration = json['maxDuration'] as String? ?? '4 hours'
      ..advance = json['advance'] as String? ?? '30 days ahead'
      ..buffer = json['buffer'] as String? ?? '15 minutes';

    final lat = (json['lat'] as num?)?.toDouble();
    final lng = (json['lng'] as num?)?.toDouble();
    if (lat != null && lng != null) d.pin = LatLng(lat, lng);

    d.geoEdited.addAll(
      (json['geoEdited'] as List?)?.cast<String>() ?? const [],
    );
    d.amenities.addAll(
      (json['amenities'] as List?)?.cast<String>() ?? const [],
    );

    final days = (json['days'] as List?)?.cast<bool>();
    if (days != null && days.length == 7) d.days = List<bool>.from(days);

    for (final raw in (json['photos'] as List?) ?? const []) {
      final photo = FacilityPhoto.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      if (photo != null) d.photos.add(photo);
    }
    return d;
  }

  bool get isDirty {
    final blank = FacilityDraft();
    return name != blank.name ||
        category != blank.category ||
        description != blank.description ||
        capacity != blank.capacity ||
        status != blank.status ||
        building != blank.building ||
        floor != blank.floor ||
        room != blank.room ||
        pin != null ||
        photos.isNotEmpty ||
        amenities.isNotEmpty ||
        requiresApproval != blank.requiresApproval ||
        maintenance != blank.maintenance ||
        publicListing != blank.publicListing ||
        !_sameDays(days, blank.days) ||
        openTime != blank.openTime ||
        closeTime != blank.closeTime ||
        maxDuration != blank.maxDuration ||
        advance != blank.advance ||
        buffer != blank.buffer;
  }

  static bool _sameDays(List<bool> a, List<bool> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
