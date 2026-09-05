import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

/// DEMO-MODE ONLY. Production point values live in
/// public.loyalty_point_rules and arrive on every AppState.loyalty refresh
/// via LoyaltySummary.rules -- Dart never computes an award. These constants
/// exist solely to seed useDemoData: true (lib/data/seed_loyalty.dart) so
/// the demo/offline app has something plausible to show.
abstract final class LoyaltyPoints {
  static const bookingCompleted = 1.0;
  static const bookingDuration1To4Hours = 0.5;
  static const bookingDuration5PlusHours = 1.0;
  static const bookingWithAmenity = 0.5;
  static const feedbackSubmitted = 1.0;
}

enum LoyaltyTransactionType {
  bookingCompleted(
    'booking_completed',
    'Completed booking',
    SrTone.success,
    Icons.event_available_rounded,
  ),
  bookingDuration1To4Hours(
    'booking_duration_1_to_4_hours',
    '1-4 hour booking',
    SrTone.info,
    Icons.schedule_rounded,
  ),
  bookingDuration5PlusHours(
    'booking_duration_5_plus_hours',
    '5+ hour booking',
    SrTone.info,
    Icons.more_time_rounded,
  ),
  bookingWithAmenity(
    'booking_with_amenity',
    'Amenity used',
    SrTone.brand,
    Icons.widgets_rounded,
  ),
  reservationCompleted(
    'reservation_completed',
    'Reservation completed (legacy)',
    SrTone.success,
    Icons.event_available_rounded,
  ),
  feedbackSubmitted(
    'feedback_submitted',
    'Feedback submitted',
    SrTone.info,
    Icons.star_rounded,
  ),
  rewardRedeemed(
    'reward_redeemed',
    'Reward redeemed',
    SrTone.brand,
    Icons.redeem_rounded,
  ),
  discountClaimed(
    'discount_claimed',
    'Discount claimed',
    SrTone.brand,
    Icons.local_offer_rounded,
  ),
  adminAdjustment(
    'admin_adjustment',
    'Adjustment',
    SrTone.neutral,
    Icons.tune_rounded,
  );

  const LoyaltyTransactionType(this.raw, this.label, this.tone, this.icon);

  final String raw;
  final String label;
  final SrTone tone;
  final IconData icon;

  static LoyaltyTransactionType fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => LoyaltyTransactionType.adminAdjustment,
  );
}

String formatPoints(num value) {
  final rounded = (value * 10).round() / 10;
  if (rounded == rounded.truncateToDouble()) {
    return rounded.toInt().toString();
  }
  return rounded.toStringAsFixed(1);
}

class LoyaltyTransaction {
  const LoyaltyTransaction({
    required this.id,
    required this.userId,
    required this.points,
    required this.type,
    required this.sourceType,
    this.sourceId,
    this.actorId,
    this.description = '',
    required this.createdAt,
  });

  final String id;
  final String userId;
  final double points;
  final LoyaltyTransactionType type;
  final String sourceType;
  final String? sourceId;
  final String? actorId;
  final String description;
  final DateTime createdAt;

  bool get isCredit => points > 0;
  String get signedLabel => (isCredit ? '+' : '') + formatPoints(points);
}

enum DiscountKind {
  fixedAmount('fixed_amount', 'Fixed PHP'),
  percentage('percentage', 'Percentage');

  const DiscountKind(this.raw, this.label);

  final String raw;
  final String label;

  static DiscountKind fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => DiscountKind.fixedAmount,
  );
}

enum LoyaltyDiscountClaimStatus {
  claimed('claimed', 'Ready', SrTone.success),
  applied('applied', 'Applied', SrTone.info),
  consumed('consumed', 'Used', SrTone.neutral),
  expired('expired', 'Expired', SrTone.neutral);

  const LoyaltyDiscountClaimStatus(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  static LoyaltyDiscountClaimStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => LoyaltyDiscountClaimStatus.claimed,
  );
}

class LoyaltyDiscountOffer {
  const LoyaltyDiscountOffer({
    required this.id,
    required this.name,
    this.description = '',
    required this.requiredPoints,
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    this.facilityId,
    this.facilityName,
    required this.validFrom,
    required this.validUntil,
    this.active = true,
    this.affordable = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final double requiredPoints;
  final DiscountKind discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final String? facilityId;
  final String? facilityName;
  final DateTime validFrom;
  final DateTime validUntil;
  final bool active;
  final bool affordable;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get scopeLabel => facilityName?.trim().isNotEmpty == true
      ? facilityName!
      : 'All guest bookings';

  String get valueLabel => switch (discountKind) {
    DiscountKind.fixedAmount =>
      'PHP ${((fixedAmountCentavos ?? 0) / 100).toStringAsFixed(2)} off',
    DiscountKind.percentage =>
      '${formatPoints(percentage ?? 0)}% off',
  };

  bool canAfford(double balance) => balance >= requiredPoints;
}

class LoyaltyDiscountApplication {
  const LoyaltyDiscountApplication({
    required this.id,
    required this.claimId,
    required this.reservationId,
    required this.discountAmountCentavos,
    required this.status,
    required this.appliedAt,
  });

  final String id;
  final String claimId;
  final String reservationId;
  final int discountAmountCentavos;
  final String status;
  final DateTime appliedAt;
}

class LoyaltyDiscountClaim {
  const LoyaltyDiscountClaim({
    required this.id,
    required this.userId,
    required this.offerId,
    required this.offerName,
    this.offerDescription = '',
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    this.facilityId,
    this.facilityName,
    required this.requiredPoints,
    required this.expiryDate,
    required this.pointsSpent,
    required this.status,
    required this.claimedAt,
    this.consumedAt,
    this.application,
  });

  final String id;
  final String userId;
  final String offerId;
  final String offerName;
  final String offerDescription;
  final DiscountKind discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final String? facilityId;
  final String? facilityName;
  final double requiredPoints;
  final DateTime expiryDate;
  final double pointsSpent;
  final LoyaltyDiscountClaimStatus status;
  final DateTime claimedAt;
  final DateTime? consumedAt;
  final LoyaltyDiscountApplication? application;

  bool get isUsable => status == LoyaltyDiscountClaimStatus.claimed;

  bool appliesTo(String targetFacilityId) =>
      facilityId == null || facilityId == targetFacilityId;

  String get scopeLabel => facilityName?.trim().isNotEmpty == true
      ? facilityName!
      : 'All guest bookings';

  String get valueLabel => switch (discountKind) {
    DiscountKind.fixedAmount =>
      'PHP ${((fixedAmountCentavos ?? 0) / 100).toStringAsFixed(2)} off',
    DiscountKind.percentage =>
      '${formatPoints(percentage ?? 0)}% off',
  };
}

class LoyaltyQuoteDiscount {
  const LoyaltyQuoteDiscount({
    required this.claimId,
    required this.offerName,
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    required this.discountAmountCentavos,
    this.expiryDate,
    this.facilityId,
  });

  final String claimId;
  final String offerName;
  final DiscountKind discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final int discountAmountCentavos;
  final DateTime? expiryDate;
  final String? facilityId;
}

enum RedemptionStatus {
  issued('issued', 'Issued', SrTone.info),
  fulfilled('fulfilled', 'Fulfilled', SrTone.success),
  cancelled('cancelled', 'Cancelled', SrTone.neutral);

  const RedemptionStatus(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  static RedemptionStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => RedemptionStatus.issued,
  );
}

class LoyaltyReward {
  LoyaltyReward({
    required this.id,
    required this.name,
    this.description = '',
    required this.pointsCost,
    this.active = true,
    this.stock,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  String name;
  String description;
  int pointsCost;
  bool active;
  int? stock;
  final DateTime createdAt;
  DateTime updatedAt;

  bool get isUnlimited => stock == null;
  bool get isOutOfStock => stock != null && stock! < 1;
  bool canAfford(num balance) => balance >= pointsCost;
}

class LoyaltyRedemption {
  const LoyaltyRedemption({
    required this.id,
    required this.userId,
    required this.rewardId,
    required this.rewardName,
    required this.pointsSpent,
    required this.status,
    required this.redemptionCode,
    required this.createdAt,
    this.fulfilledAt,
  });

  final String id;
  final String userId;
  final String rewardId;
  final String rewardName;
  final int pointsSpent;
  final RedemptionStatus status;
  final String redemptionCode;
  final DateTime createdAt;
  final DateTime? fulfilledAt;
}

/// One round trip's worth of everything the student loyalty page needs.
class LoyaltySummary {
  const LoyaltySummary({
    this.eligible = true,
    this.balance = 0,
    this.lifetimeEarned = 0,
    this.lifetimeRedeemed = 0,
    this.rules = const {},
    this.transactions = const [],
    this.redemptions = const [],
    this.rewards = const [],
    this.offers = const [],
    this.claims = const [],
  });

  final bool eligible;
  final double balance;
  final double lifetimeEarned;
  final double lifetimeRedeemed;

  /// Server-configured earning values, keyed by
  /// LoyaltyTransactionType.raw -- e.g. {'booking_with_amenity': 0.5}.
  /// Copy like "Earn N points" should always read from here, never from
  /// [LoyaltyPoints].
  final Map<String, double> rules;
  final List<LoyaltyTransaction> transactions;
  final List<LoyaltyRedemption> redemptions;
  final List<LoyaltyReward> rewards;
  final List<LoyaltyDiscountOffer> offers;
  final List<LoyaltyDiscountClaim> claims;

  double ruleFor(LoyaltyTransactionType type) => rules[type.raw] ?? 0;
}

/// One row of the admin balances table.
class LoyaltyBalanceRow {
  const LoyaltyBalanceRow({
    required this.userId,
    required this.fullName,
    required this.email,
    required this.balance,
    required this.lifetimeEarned,
    required this.lifetimeRedeemed,
    this.lastActivityAt,
  });

  final String userId;
  final String fullName;
  final String email;
  final double balance;
  final double lifetimeEarned;
  final double lifetimeRedeemed;
  final DateTime? lastActivityAt;
}

class LoyaltyAdminClaimRow {
  const LoyaltyAdminClaimRow({
    required this.claimId,
    required this.renterUserId,
    required this.renterFullName,
    required this.renterEmail,
    required this.offerId,
    required this.offerName,
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    this.facilityId,
    this.facilityName,
    required this.pointsSpent,
    required this.expiryDate,
    required this.status,
    required this.effectiveStatus,
    this.applicationId,
    this.applicationStatus,
    this.releaseReason,
    this.appliedAt,
    this.releasedAt,
    this.applicationConsumedAt,
    this.reservationId,
    required this.claimedAt,
    this.consumedAt,
    required this.createdAt,
  });

  final String claimId;
  final String renterUserId;
  final String renterFullName;
  final String renterEmail;
  final String offerId;
  final String offerName;
  final DiscountKind discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final String? facilityId;
  final String? facilityName;
  final double pointsSpent;
  final DateTime expiryDate;
  final LoyaltyDiscountClaimStatus status;
  final LoyaltyDiscountClaimStatus effectiveStatus;
  final String? applicationId;
  final String? applicationStatus;
  final String? releaseReason;
  final DateTime? appliedAt;
  final DateTime? releasedAt;
  final DateTime? applicationConsumedAt;
  final String? reservationId;
  final DateTime claimedAt;
  final DateTime? consumedAt;
  final DateTime createdAt;

  String get renterLabel =>
      renterFullName.trim().isEmpty ? renterEmail : renterFullName;

  String get scopeLabel => facilityName?.trim().isNotEmpty == true
      ? facilityName!
      : 'All guest bookings';

  String get valueLabel => switch (discountKind) {
    DiscountKind.fixedAmount =>
      'PHP ${((fixedAmountCentavos ?? 0) / 100).toStringAsFixed(2)} off',
    DiscountKind.percentage =>
      '${formatPoints(percentage ?? 0)}% off',
  };
}
