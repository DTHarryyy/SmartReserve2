import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

/// Written-feedback validation limits, mirrored exactly by the CHECK
/// constraint on `public.reservation_feedback.comment` in
/// 20260823090000_reservation_feedback_and_loyalty.sql.
abstract final class FeedbackLimits {
  static const commentMax = 500;
}

enum FeedbackRating {
  poor(1, 'Poor', SrTone.error),
  fair(2, 'Fair', SrTone.warning),
  good(3, 'Good', SrTone.warning),
  veryGood(4, 'Very Good', SrTone.success),
  excellent(5, 'Excellent', SrTone.success);

  const FeedbackRating(this.value, this.label, this.tone);

  final int value;
  final String label;
  final SrTone tone;

  Color get background => tone.tint;
  Color get foreground => tone.ink;

  static FeedbackRating? fromValue(int? value) {
    if (value == null) return null;
    for (final rating in values) {
      if (rating.value == value) return rating;
    }
    return null;
  }
}

/// A user's review of a completed reservation. Mutable UI model, no
/// fromJson -- parsing lives on the wire DTO in supabase_service.dart,
/// matching the rest of lib/model/*.
class ReservationFeedback {
  ReservationFeedback({
    required this.id,
    required this.reservationId,
    required this.facilityId,
    required this.facilityName,
    required this.userId,
    required this.rating,
    this.cleanlinessRating,
    this.conditionRating,
    this.equipmentRating,
    this.comment = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String reservationId;
  final String facilityId;
  String facilityName;
  final String userId;
  int rating;
  int? cleanlinessRating;
  int? conditionRating;
  int? equipmentRating;
  String comment;
  final DateTime createdAt;
  DateTime updatedAt;

  FeedbackRating? get ratingTier => FeedbackRating.fromValue(rating);
}

/// One row in the admin feedback list -- the review plus the reservation and
/// reviewer context an administrator needs, in a single fetch.
class FeedbackEntry {
  FeedbackEntry({
    required this.feedback,
    required this.reviewerName,
  });

  final ReservationFeedback feedback;
  final String reviewerName;
}

class FacilityRatingStat {
  const FacilityRatingStat({
    required this.facilityId,
    required this.facilityName,
    required this.average,
    required this.total,
  });

  final String facilityId;
  final String facilityName;
  final double average;
  final int total;
}

class FeedbackSummary {
  const FeedbackSummary({
    this.average,
    this.total = 0,
    this.fiveStar = 0,
    this.lowRated = 0,
    this.highest = const [],
    this.lowest = const [],
  });

  final double? average;
  final int total;
  final int fiveStar;
  final int lowRated;
  final List<FacilityRatingStat> highest;
  final List<FacilityRatingStat> lowest;

  bool get isEmpty => total == 0;
}

/// FeedbackQuery (the server-side filter object for the admin feedback
/// list) lives in supabase_service.dart as a wire DTO, matching where
/// AuditQuery lives -- not here.
enum FeedbackSort { newest, oldest, highest, lowest }
