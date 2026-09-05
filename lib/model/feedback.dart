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

enum SentimentLabel {
  positive('positive', 'Positive', SrTone.success),
  neutral('neutral', 'Neutral', SrTone.neutral),
  negative('negative', 'Negative', SrTone.error),
  mixed('mixed', 'Mixed', SrTone.info),
  unknown('unknown', 'Unknown', SrTone.neutral);

  const SentimentLabel(this.value, this.label, this.tone);

  final String value;
  final String label;
  final SrTone tone;

  static SentimentLabel? fromValue(String? value) {
    if (value == null) return null;
    for (final sentiment in values) {
      if (sentiment.value == value) return sentiment;
    }
    return null;
  }
}

enum SentimentAnalysisStatus {
  notAnalyzed('not_analyzed', 'Not analyzed', SrTone.neutral),
  pending('pending', 'Pending', SrTone.neutral),
  processing('processing', 'Processing', SrTone.info),
  completed('completed', 'Completed', SrTone.success),
  failed('failed', 'Analysis unavailable', SrTone.warning),
  skipped('skipped', 'No comment', SrTone.neutral);

  const SentimentAnalysisStatus(this.value, this.label, this.tone);

  final String value;
  final String label;
  final SrTone tone;

  bool get isRetryable => this == failed;
  bool get isBusy => this == pending || this == processing;

  static SentimentAnalysisStatus fromValue(String? value) {
    if (value == null) return SentimentAnalysisStatus.notAnalyzed;
    for (final status in values) {
      if (status.value == value) return status;
    }
    return SentimentAnalysisStatus.notAnalyzed;
  }
}

enum FeedbackTopic {
  facilityCleanliness('facility_cleanliness', 'Cleanliness'),
  facilityCondition('facility_condition', 'Facility condition'),
  reservationProcess('reservation_process', 'Reservation process'),
  approvalSpeed('approval_speed', 'Approval speed'),
  staffService('staff_service', 'Staff service'),
  paymentProcess('payment_process', 'Payment process'),
  equipmentAvailability('equipment_availability', 'Equipment'),
  overallExperience('overall_experience', 'Overall experience'),
  other('other', 'Other');

  const FeedbackTopic(this.value, this.label);

  final String value;
  final String label;

  static FeedbackTopic? fromValue(String? value) {
    if (value == null) return null;
    for (final topic in values) {
      if (topic.value == value) return topic;
    }
    return null;
  }
}

class FeedbackTopicSentiment {
  const FeedbackTopicSentiment({required this.topic, required this.sentiment});

  final FeedbackTopic topic;
  final SentimentLabel sentiment;
}

class FeedbackSentimentAnalysis {
  const FeedbackSentimentAnalysis({
    required this.id,
    required this.feedbackId,
    required this.analysisVersion,
    required this.status,
    this.sentiment,
    this.confidence,
    this.topics = const [],
    this.provider,
    this.model,
    this.attemptCount = 0,
    this.lastErrorCode,
    this.processingStartedAt,
    this.analyzedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String feedbackId;
  final int analysisVersion;
  final SentimentAnalysisStatus status;
  final SentimentLabel? sentiment;
  final double? confidence;
  final List<FeedbackTopicSentiment> topics;
  final String? provider;
  final String? model;
  final int attemptCount;
  final String? lastErrorCode;
  final DateTime? processingStartedAt;
  final DateTime? analyzedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasNegativeTopic =>
      topics.any((topic) => topic.sentiment == SentimentLabel.negative);

  bool get isLowConfidence =>
      status == SentimentAnalysisStatus.completed &&
      confidence != null &&
      confidence! < 0.60;

  bool needsReviewForRating(int rating) =>
      rating <= 2 || sentiment == SentimentLabel.negative || hasNegativeTopic;

  bool ratingMismatchFor(int rating) =>
      status == SentimentAnalysisStatus.completed &&
      ((rating >= 4 && sentiment == SentimentLabel.negative) ||
          (rating <= 2 && sentiment == SentimentLabel.positive));
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
    this.sentimentAnalysis,
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
  FeedbackSentimentAnalysis? sentimentAnalysis;

  FeedbackRating? get ratingTier => FeedbackRating.fromValue(rating);

  SentimentAnalysisStatus get sentimentStatus =>
      sentimentAnalysis?.status ?? SentimentAnalysisStatus.notAnalyzed;

  bool get needsReview =>
      sentimentAnalysis?.needsReviewForRating(rating) ?? rating <= 2;

  bool get ratingSentimentMismatch =>
      sentimentAnalysis?.ratingMismatchFor(rating) ?? false;
}

/// One row in the admin feedback list -- the review plus the reservation and
/// reviewer context an administrator needs, in a single fetch.
class FeedbackEntry {
  FeedbackEntry({
    required this.feedback,
    required this.reviewerName,
    this.reservationStartsAt,
    this.pricingAudience = '',
  });

  final ReservationFeedback feedback;
  final String reviewerName;
  final DateTime? reservationStartsAt;
  final String pricingAudience;
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

class FeedbackSentimentTrendPoint {
  const FeedbackSentimentTrendPoint({
    required this.bucketStart,
    this.positive = 0,
    this.neutral = 0,
    this.negative = 0,
    this.mixed = 0,
    this.classified = 0,
    this.averageRating,
  });

  final DateTime bucketStart;
  final int positive;
  final int neutral;
  final int negative;
  final int mixed;
  final int classified;
  final double? averageRating;
}

class FacilitySentimentInsight {
  const FacilitySentimentInsight({
    required this.facilityId,
    required this.facilityName,
    this.classified = 0,
    this.positive = 0,
    this.neutral = 0,
    this.negative = 0,
    this.mixed = 0,
    this.needsReview = 0,
    this.averageRating,
  });

  final String facilityId;
  final String facilityName;
  final int classified;
  final int positive;
  final int neutral;
  final int negative;
  final int mixed;
  final int needsReview;
  final double? averageRating;

  double get negativeShare => classified == 0 ? 0 : negative / classified;
}

class ComplaintTopicInsight {
  const ComplaintTopicInsight({
    required this.topic,
    this.count = 0,
    this.facilityCount = 0,
  });

  final FeedbackTopic topic;
  final int count;
  final int facilityCount;
}

class FeedbackSentimentAnalytics {
  const FeedbackSentimentAnalytics({
    this.totalFeedback = 0,
    this.writtenFeedback = 0,
    this.classifiedFeedback = 0,
    this.pending = 0,
    this.processing = 0,
    this.failed = 0,
    this.skipped = 0,
    this.notAnalyzed = 0,
    this.averageRating,
    this.positive = 0,
    this.neutral = 0,
    this.negative = 0,
    this.mixed = 0,
    this.unknown = 0,
    this.needsReview = 0,
    this.ratingMismatch = 0,
    this.trendBucket = 'day',
    this.trend = const [],
    this.facilities = const [],
    this.complaints = const [],
  });

  final int totalFeedback;
  final int writtenFeedback;
  final int classifiedFeedback;
  final int pending;
  final int processing;
  final int failed;
  final int skipped;
  final int notAnalyzed;
  final double? averageRating;
  final int positive;
  final int neutral;
  final int negative;
  final int mixed;
  final int unknown;
  final int needsReview;
  final int ratingMismatch;
  final String trendBucket;
  final List<FeedbackSentimentTrendPoint> trend;
  final List<FacilitySentimentInsight> facilities;
  final List<ComplaintTopicInsight> complaints;

  int get percentageDenominator => positive + neutral + negative + mixed;

  double? shareFor(int count) =>
      percentageDenominator == 0 ? null : count / percentageDenominator;

  double? get positiveShare => shareFor(positive);
  double? get negativeShare => shareFor(negative);

  bool get hasAnyAnalysis =>
      classifiedFeedback > 0 ||
      pending > 0 ||
      processing > 0 ||
      failed > 0 ||
      skipped > 0;

  bool get hasRenderableTrend =>
      trend.where((point) => point.classified > 0).length >= 2 &&
      trend.fold<int>(0, (total, point) => total + point.classified) >= 3;
}

/// FeedbackQuery (the server-side filter object for the admin feedback
/// list) lives in supabase_service.dart as a wire DTO, matching where
/// AuditQuery lives -- not here.
enum FeedbackSort { newest, oldest, highest, lowest }
