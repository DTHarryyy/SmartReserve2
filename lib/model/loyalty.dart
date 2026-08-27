import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

/// DEMO-MODE ONLY. Production point values live in
/// public.loyalty_point_rules and arrive on every AppState.loyalty refresh
/// via LoyaltySummary.rules -- Dart never computes an award. These constants
/// exist solely to seed useDemoData: true (lib/data/seed_loyalty.dart) so
/// the demo/offline app has something plausible to show.
abstract final class LoyaltyPoints {
  static const reservationCompleted = 10;
  static const feedbackSubmitted = 5;
}

enum LoyaltyTransactionType {
  reservationCompleted(
    'reservation_completed',
    'Reservation completed',
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

class LoyaltyTransaction {
  const LoyaltyTransaction({
    required this.id,
    required this.userId,
    required this.points,
    required this.type,
    required this.sourceType,
    this.sourceId,
    this.description = '',
    required this.createdAt,
  });

  final String id;
  final String userId;
  final int points;
  final LoyaltyTransactionType type;
  final String sourceType;
  final String? sourceId;
  final String description;
  final DateTime createdAt;

  bool get isCredit => points > 0;
  String get signedLabel => (isCredit ? '+' : '') + points.toString();
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
  bool canAfford(int balance) => balance >= pointsCost;
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
  });

  final bool eligible;
  final int balance;
  final int lifetimeEarned;
  final int lifetimeRedeemed;

  /// Server-configured earning values, keyed by
  /// LoyaltyTransactionType.raw -- e.g. {'reservation_completed': 10}.
  /// Copy like "Earn N points" should always read from here, never from
  /// [LoyaltyPoints].
  final Map<String, int> rules;
  final List<LoyaltyTransaction> transactions;
  final List<LoyaltyRedemption> redemptions;
  final List<LoyaltyReward> rewards;

  int ruleFor(LoyaltyTransactionType type) => rules[type.raw] ?? 0;
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
  final int balance;
  final int lifetimeEarned;
  final int lifetimeRedeemed;
  final DateTime? lastActivityAt;
}
