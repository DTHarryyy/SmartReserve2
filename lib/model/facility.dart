import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../theme/sr_tokens.dart';
import 'facility_photo.dart';
import 'payment.dart';

enum PinConfidence {
  verified('verified', 'VERIFIED', SrTone.success),
  needsCheck('needs check', 'NEEDS CHECK', SrTone.warning),
  none('no pin', 'NO PIN', SrTone.neutral);

  const PinConfidence(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  Color get color => tone.ink;

  static PinConfidence fromRaw(String raw) =>
      values.firstWhere((p) => p.raw == raw, orElse: () => PinConfidence.none);
}

enum FacilityState {
  active('Active', SrTone.success),
  underReview('Under review', SrTone.info),
  maintenance('Maintenance', SrTone.warning),
  draft('Draft', SrTone.neutral);

  const FacilityState(this.label, this.tone);

  final String label;
  final SrTone tone;

  Color get background => tone.tint;
  Color get foreground => tone.ink;
  Color get dot => tone.solid;

  static FacilityState fromLabel(String label) => values.firstWhere(
    (s) => s.label == label,
    orElse: () => FacilityState.draft,
  );
}

class FacilityAmenity {
  const FacilityAmenity({
    required this.id,
    required this.name,
    required this.priceCentavos,
    this.description = '',
    this.pricingUnit = 'per_occurrence',
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final int priceCentavos;
  final String pricingUnit;
  final bool enabled;
}

class FacilityAudienceRate {
  const FacilityAudienceRate({
    required this.audience,
    required this.hourlyRateCentavos,
    this.enabled = true,
  });

  final String audience;
  final int hourlyRateCentavos;
  final bool enabled;
}

/// Why a facility currently cannot be booked by the signed-in account, as
/// reported by `my_facility_access.booking_unavailability_code`. This is a
/// requester-eligibility signal, not an administrator-assignment one: a
/// facility has no per-facility owner any more, only a global lane of
/// active administrators.
enum FacilityBookingBlockReason {
  noActiveInternalAdmin('no_active_internal_admin'),
  noActiveExternalAdmin('no_active_external_admin'),
  notAvailableForAccountType('facility_not_available_for_account_type'),
  facilityInactive('facility_inactive');

  const FacilityBookingBlockReason(this.code);

  final String code;

  static FacilityBookingBlockReason? fromCode(String? code) {
    if (code == null) return null;
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
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
    this.amenityOptions = const [],
    this.paymentMethods = const [],
    this.audienceRates = const [],
    this.canManage = true,
    this.bookableForCurrentUser = true,
    this.supportsInternalLane = true,
    this.supportsExternalLane = true,
    this.bookingBlockReason,
    this.facilityClassification = 'shared',
    this.depositWindowMinutes = 1440,
    this.balanceDueLeadDays = 3,
    this.balanceDueLeadMinutes = 1440,
    this.paymentCorrectionWindowMinutes = 1440,
    this.downPaymentPercent = 50,
    this.ratingAverage,
    this.ratingCount = 0,
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
  List<FacilityAmenity> amenityOptions;
  List<FacilityPaymentMethod> paymentMethods;
  List<FacilityAudienceRate> audienceRates;
  bool canManage;
  bool bookableForCurrentUser;
  bool supportsInternalLane;
  bool supportsExternalLane;
  FacilityBookingBlockReason? bookingBlockReason;
  String facilityClassification;
  int depositWindowMinutes;
  int balanceDueLeadDays;
  int balanceDueLeadMinutes;
  int paymentCorrectionWindowMinutes;
  int downPaymentPercent;

  /// Null when the facility has no reviews yet -- backed by
  /// public.facility_rating_stats, never stored on the facilities row
  /// itself (see the migration header for why).
  double? ratingAverage;
  int ratingCount;

  bool get hasRatings => ratingCount > 0;
  String get ratingLabel => hasRatings
      ? '${ratingAverage!.toStringAsFixed(1)} ★ · $ratingCount ${ratingCount == 1 ? 'review' : 'reviews'}'
      : 'No reviews yet';

  FacilityPhoto? get coverPhoto => photos.isEmpty ? null : photos.first;

  int hourlyRateCentavosFor(String audience) {
    for (final rate in audienceRates) {
      if (rate.enabled && rate.audience == audience) {
        return rate.hourlyRateCentavos;
      }
    }
    return 0;
  }

  int get thumbHue => (name.hashCode.abs() % 360);

  IconData get categoryIcon => switch (category) {
    'Computer Laboratory' => Icons.computer_rounded,
    'Science Laboratory' => Icons.science_rounded,
    'Auditorium' => Icons.theater_comedy_rounded,
    'Library Space' => Icons.menu_book_rounded,
    'Gymnasium' => Icons.sports_basketball_rounded,
    'Conference Room' => Icons.groups_rounded,
    _ => Icons.apartment_rounded,
  };

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

  bool opensOn(DateTime date) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final day = names[date.weekday - 1];
    if (days == 'Mon–Sun') return true;
    if (days == 'Mon–Sat') return date.weekday <= DateTime.saturday;
    if (days == 'Mon–Fri') return date.weekday <= DateTime.friday;
    return days.split(',').map((part) => part.trim()).contains(day);
  }
}
