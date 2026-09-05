import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/feedback.dart';

void main() {
  group('FeedbackSentimentAnalysis', () {
    FeedbackSentimentAnalysis analysis({
      SentimentLabel sentiment = SentimentLabel.positive,
      List<FeedbackTopicSentiment> topics = const [],
      double confidence = 0.9,
    }) {
      final now = DateTime(2026, 8, 29);
      return FeedbackSentimentAnalysis(
        id: 'analysis-1',
        feedbackId: 'feedback-1',
        analysisVersion: 1,
        status: SentimentAnalysisStatus.completed,
        sentiment: sentiment,
        confidence: confidence,
        topics: topics,
        provider: 'groq',
        model: 'openai/gpt-oss-20b',
        analyzedAt: now,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('keeps rating and text sentiment as separate mismatch signals', () {
      expect(
        analysis(sentiment: SentimentLabel.negative).ratingMismatchFor(5),
        isTrue,
      );
      expect(
        analysis(sentiment: SentimentLabel.positive).ratingMismatchFor(1),
        isTrue,
      );
      expect(
        analysis(sentiment: SentimentLabel.neutral).ratingMismatchFor(5),
        isFalse,
      );
    });

    test('flags needs-review rows without overwriting the star rating', () {
      expect(
        analysis(sentiment: SentimentLabel.negative).needsReviewForRating(5),
        isTrue,
      );
      expect(
        analysis(sentiment: SentimentLabel.positive).needsReviewForRating(2),
        isTrue,
      );
      expect(
        analysis(
          sentiment: SentimentLabel.mixed,
          topics: const [
            FeedbackTopicSentiment(
              topic: FeedbackTopic.approvalSpeed,
              sentiment: SentimentLabel.negative,
            ),
          ],
        ).needsReviewForRating(4),
        isTrue,
      );
    });

    test('marks low confidence only for completed analysis', () {
      expect(analysis(confidence: 0.59).isLowConfidence, isTrue);
      final now = DateTime(2026, 8, 29);
      final pending = FeedbackSentimentAnalysis(
        id: 'analysis-2',
        feedbackId: 'feedback-2',
        analysisVersion: 1,
        status: SentimentAnalysisStatus.pending,
        confidence: 0.4,
        createdAt: now,
        updatedAt: now,
      );
      expect(pending.isLowConfidence, isFalse);
    });
  });

  group('FeedbackSentimentAnalytics', () {
    test('excludes unknown and operational statuses from percentages', () {
      const analytics = FeedbackSentimentAnalytics(
        positive: 6,
        neutral: 2,
        negative: 1,
        mixed: 1,
        unknown: 4,
        pending: 3,
        skipped: 2,
      );

      expect(analytics.percentageDenominator, 10);
      expect(analytics.positiveShare, 0.6);
      expect(analytics.negativeShare, 0.1);
    });

    test('requires enough populated buckets before rendering a trend', () {
      final sparse = FeedbackSentimentAnalytics(
        trend: [
          FeedbackSentimentTrendPoint(
            bucketStart: DateTime(2026, 8, 1),
            classified: 2,
          ),
        ],
      );
      final enough = FeedbackSentimentAnalytics(
        trend: [
          FeedbackSentimentTrendPoint(
            bucketStart: DateTime(2026, 8, 1),
            classified: 1,
          ),
          FeedbackSentimentTrendPoint(
            bucketStart: DateTime(2026, 8, 2),
            classified: 2,
          ),
        ],
      );

      expect(sparse.hasRenderableTrend, isFalse);
      expect(enough.hasRenderableTrend, isTrue);
    });
  });
}
