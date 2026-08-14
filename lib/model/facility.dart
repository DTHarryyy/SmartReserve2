import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../theme/sr_tokens.dart';
import 'facility_photo.dart';

enum PinConfidence {
  verified('verified', 'VERIFIED', SR.greenDark),
  needsCheck('needs check', 'NEEDS CHECK', SR.amber),
  none('no pin', 'NO PIN', SR.muted);

  const PinConfidence(this.raw, this.label, this.color);

  final String raw;
  final String label;
  final Color color;

  static PinConfidence fromRaw(String raw) =>
      values.firstWhere((p) => p.raw == raw, orElse: () => PinConfidence.none);
}

enum FacilityState {
  active('Active', SR.greenTint, SR.greenDark, SR.green),
  underReview('Under review', SR.blueTint, SR.blueDark, SR.blue),
  maintenance('Maintenance', SR.amberTint, SR.amber, SR.orange),
  draft('Draft', SR.dividerSoft, SR.ink4, SR.muted);

  const FacilityState(this.label, this.background, this.foreground, this.dot);

  final String label;
  final Color background;
  final Color foreground;
  final Color dot;

  static FacilityState fromLabel(String label) => values.firstWhere(
    (s) => s.label == label,
    orElse: () => FacilityState.draft,
  );
}

class Facility {
  Facility({
    required this.id,
    required this.name,
    required this.room,
    required this.building,
    required this.category,
    required this.capacity,
    required this.pinConfidence,
    required this.state,
    required this.floor,
    required this.coords,
    required this.accuracy,
    required this.description,
    required this.amenities,
    required this.hours,
    required this.days,
    required this.approvalRequired,
    required this.maxDuration,
    required this.advance,
    required this.updated,
    required this.bookings,
    this.photoCount = 3,
    this.confirmedOutside = false,
    this.campusName = 'CSU Aparri Campus',
    this.buffer = '15 minutes',
    this.publicListing = true,
    this.photos = const [],
    this.geoBuilding = '',
    this.street = '',
    this.barangay = '',
    this.municipality = '',
    this.province = '',
    this.region = '',
    this.country = '',
    this.geoEdited = const [],
    this.maxDurationMinutes = 240,
    this.advanceBookingDays = 30,
    this.bookingBufferMinutes = 15,
  });

  final String id;
  String name;
  String room;
  String building;
  String category;
  int capacity;
  PinConfidence pinConfidence;
  FacilityState state;
  String floor;
  LatLng? coords;
  int? accuracy;
  String description;
  List<String> amenities;

  String hours;

  String days;
  bool approvalRequired;
  String maxDuration;
  String advance;
  String buffer;
  bool publicListing;
  String campusName;

  String updated;

  int bookings;

  int photoCount;

  bool confirmedOutside;

  List<FacilityPhoto> photos;
  String geoBuilding;
  String street;
  String barangay;
  String municipality;
  String province;
  String region;
  String country;
  List<String> geoEdited;
  int maxDurationMinutes;
  int advanceBookingDays;
  int bookingBufferMinutes;

  FacilityPhoto? get coverPhoto => photos.isEmpty ? null : photos.first;

  int get thumbHue => (name.hashCode.abs() % 360);

  String get whereLine {
    final parts = [
      if (building.isNotEmpty) building,
      if (floor.isNotEmpty) floor,
      if (room.trim().isNotEmpty) room.trim(),
    ];
    return parts.isEmpty ? 'Location not set' : parts.join(' · ');
  }

  int get openHour =>
      int.tryParse(hours.split('–').first.split(':').first) ?? 7;

  int get closeHour =>
      int.tryParse(hours.split('–').last.split(':').first) ?? 19;

  int get operatingHoursPerDay => (closeHour - openHour).clamp(0, 24);

  int get openDaysPerWeek => switch (days) {
    'Mon–Sun' => 7,
    'Mon–Sat' => 6,
    'Mon–Fri' => 5,
    _ => days.split(',').length,
  };

  /// Whether this facility is open on the given weekday, per [days]
  /// (`"Mon–Sun"`, `"Mon–Sat"`, `"Mon–Fri"`, or a comma list like `"Mon, Wed, Fri"`).
  bool opensOn(DateTime date) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final day = names[date.weekday - 1];
    if (days == 'Mon–Sun') return true;
    if (days == 'Mon–Sat') return date.weekday <= DateTime.saturday;
    if (days == 'Mon–Fri') return date.weekday <= DateTime.friday;
    return days.split(',').map((part) => part.trim()).contains(day);
  }
}
