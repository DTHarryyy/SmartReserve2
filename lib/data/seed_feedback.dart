import '../model/feedback.dart';

/// Demo-mode feedback. Empty by default so the "Rate your visit" flow on
/// seed reservation r9 (see seed_reservations.dart) is live and testable;
/// AppState.submitFeedback appends to this in memory when useDemoData is
/// true.
List<ReservationFeedback> seedFeedback() => [];

FeedbackSummary demoFeedbackSummary(List<ReservationFeedback> entries) {
  if (entries.isEmpty) return const FeedbackSummary();
  final total = entries.length;
  final sum = entries.fold<int>(0, (value, item) => value + item.rating);
  final fiveStar = entries.where((item) => item.rating == 5).length;
  final lowRated = entries.where((item) => item.rating <= 2).length;
  return FeedbackSummary(
    average: sum / total,
    total: total,
    fiveStar: fiveStar,
    lowRated: lowRated,
  );
}
