import '../model/loyalty.dart';

LoyaltySummary seedLoyalty({String userId = 'u5'}) {
  final transactions = [
    LoyaltyTransaction(
      id: 'lt1',
      userId: userId,
      points: LoyaltyPoints.bookingCompleted,
      type: LoyaltyTransactionType.bookingCompleted,
      sourceType: 'reservation',
      sourceId: 'r7',
      description: 'Completed reservation at Computer Laboratory 1',
      createdAt: DateTime(2026, 7, 24, 12, 5),
    ),
    LoyaltyTransaction(
      id: 'lt2',
      userId: userId,
      points: LoyaltyPoints.feedbackSubmitted,
      type: LoyaltyTransactionType.feedbackSubmitted,
      sourceType: 'feedback',
      sourceId: 'fb-demo-1',
      description: 'Feedback for Computer Laboratory 1',
      createdAt: DateTime(2026, 7, 24, 12, 6),
    ),
    LoyaltyTransaction(
      id: 'lt3',
      userId: userId,
      points: LoyaltyPoints.bookingDuration1To4Hours,
      type: LoyaltyTransactionType.bookingDuration1To4Hours,
      sourceType: 'reservation',
      sourceId: 'r-demo-older',
      description: '1-4 hour booking at Reading Hall B',
      createdAt: DateTime(2026, 7, 10, 9, 0),
    ),
  ];
  final offers = [
    LoyaltyDiscountOffer(
      id: 'offer-php-100',
      name: 'PHP 100 booking discount',
      description: 'Save PHP 100 on one future guest booking.',
      requiredPoints: 2.0,
      discountKind: DiscountKind.fixedAmount,
      fixedAmountCentavos: 10000,
      validFrom: DateTime(2026, 6),
      validUntil: DateTime(2026, 12, 31),
      affordable: true,
      createdAt: DateTime(2026, 6, 1),
      updatedAt: DateTime(2026, 6, 1),
    ),
    LoyaltyDiscountOffer(
      id: 'offer-ten-percent',
      name: '10% facility discount',
      description: 'Take 10% off one guest booking.',
      requiredPoints: 3.5,
      discountKind: DiscountKind.percentage,
      percentage: 10,
      validFrom: DateTime(2026, 6),
      validUntil: DateTime(2026, 12, 31),
      affordable: false,
      createdAt: DateTime(2026, 6, 1),
      updatedAt: DateTime(2026, 6, 1),
    ),
  ];
  final balance = transactions.fold<double>(
    0,
    (value, item) => value + item.points,
  );
  final earned = transactions
      .where((item) => item.isCredit)
      .fold<double>(0, (value, item) => value + item.points);
  return LoyaltySummary(
    eligible: true,
    balance: balance,
    lifetimeEarned: earned,
    lifetimeRedeemed: 0,
    rules: const {
      'booking_completed': LoyaltyPoints.bookingCompleted,
      'booking_duration_1_to_4_hours': LoyaltyPoints.bookingDuration1To4Hours,
      'booking_duration_5_plus_hours': LoyaltyPoints.bookingDuration5PlusHours,
      'booking_with_amenity': LoyaltyPoints.bookingWithAmenity,
      'feedback_submitted': LoyaltyPoints.feedbackSubmitted,
    },
    transactions: transactions,
    redemptions: const [],
    rewards: const [],
    offers: offers,
    claims: const [],
  );
}
