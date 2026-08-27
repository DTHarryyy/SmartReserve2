import '../model/loyalty.dart';

LoyaltySummary seedLoyalty({String userId = 'u5'}) {
  final transactions = [
    LoyaltyTransaction(
      id: 'lt1',
      userId: userId,
      points: LoyaltyPoints.reservationCompleted,
      type: LoyaltyTransactionType.reservationCompleted,
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
      points: LoyaltyPoints.reservationCompleted,
      type: LoyaltyTransactionType.reservationCompleted,
      sourceType: 'reservation',
      sourceId: 'r-demo-older',
      description: 'Completed reservation at Reading Hall B',
      createdAt: DateTime(2026, 7, 10, 9, 0),
    ),
  ];
  final rewards = [
    LoyaltyReward(
      id: 'reward-priority',
      name: 'Priority reservation review',
      description:
          'Your next reservation request jumps to the front of the queue.',
      pointsCost: 20,
      createdAt: DateTime(2026, 6, 1),
      updatedAt: DateTime(2026, 6, 1),
    ),
    LoyaltyReward(
      id: 'reward-extended',
      name: 'Extended booking window',
      description: 'Book up to 45 days ahead for one reservation.',
      pointsCost: 40,
      createdAt: DateTime(2026, 6, 1),
      updatedAt: DateTime(2026, 6, 1),
    ),
    LoyaltyReward(
      id: 'reward-merch',
      name: 'Campus sticker pack',
      description: 'A small pack of campus stickers, pick up at the SASO.',
      pointsCost: 60,
      stock: 25,
      createdAt: DateTime(2026, 6, 1),
      updatedAt: DateTime(2026, 6, 1),
    ),
  ];
  final balance = transactions.fold<int>(
    0,
    (value, item) => value + item.points,
  );
  final earned = transactions
      .where((item) => item.isCredit)
      .fold<int>(0, (value, item) => value + item.points);
  return LoyaltySummary(
    eligible: true,
    balance: balance,
    lifetimeEarned: earned,
    lifetimeRedeemed: 0,
    rules: const {
      'reservation_completed': LoyaltyPoints.reservationCompleted,
      'feedback_submitted': LoyaltyPoints.feedbackSubmitted,
    },
    transactions: transactions,
    redemptions: const [],
    rewards: rewards,
  );
}
