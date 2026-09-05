import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/feedback.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/record_table.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

enum _RatingFilter { all, five, four, three, two, one, low }

enum _SentimentFilter {
  all(null, 'All sentiment'),
  positive(SentimentLabel.positive, 'Positive'),
  neutral(SentimentLabel.neutral, 'Neutral'),
  negative(SentimentLabel.negative, 'Negative'),
  mixed(SentimentLabel.mixed, 'Mixed'),
  unknown(SentimentLabel.unknown, 'Unknown');

  const _SentimentFilter(this.sentiment, this.label);

  final SentimentLabel? sentiment;
  final String label;
}

enum _AnalysisStatusFilter {
  all(null, 'All analysis'),
  pending(SentimentAnalysisStatus.pending, 'Pending'),
  processing(SentimentAnalysisStatus.processing, 'Processing'),
  completed(SentimentAnalysisStatus.completed, 'Completed'),
  failed(SentimentAnalysisStatus.failed, 'Unavailable'),
  skipped(SentimentAnalysisStatus.skipped, 'No comment'),
  notAnalyzed(SentimentAnalysisStatus.notAnalyzed, 'Not analyzed');

  const _AnalysisStatusFilter(this.status, this.label);

  final SentimentAnalysisStatus? status;
  final String label;
}

enum _DateFilter {
  all('All time'),
  sevenDays('Last 7 days'),
  thirtyDays('Last 30 days'),
  semester('This semester');

  const _DateFilter(this.label);

  final String label;
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final TextEditingController _search = TextEditingController();

  String _facilityName = 'All facilities';
  _RatingFilter _rating = _RatingFilter.all;
  _SentimentFilter _sentiment = _SentimentFilter.all;
  _AnalysisStatusFilter _analysisStatus = _AnalysisStatusFilter.all;
  FeedbackTopic? _topic;
  _DateFilter _date = _DateFilter.all;
  bool _needsReviewOnly = false;
  FeedbackSort _sort = FeedbackSort.newest;

  static const _ratingLabels = {
    _RatingFilter.all: 'All ratings',
    _RatingFilter.five: '5 stars',
    _RatingFilter.four: '4 stars',
    _RatingFilter.three: '3 stars',
    _RatingFilter.two: '2 stars',
    _RatingFilter.one: '1 star',
    _RatingFilter.low: 'Low (1-2)',
  };

  static const _sortLabels = {
    FeedbackSort.newest: 'Newest',
    FeedbackSort.oldest: 'Oldest',
    FeedbackSort.highest: 'Highest rated',
    FeedbackSort.lowest: 'Lowest rated',
  };

  static const _columns = <ColSpec>[
    ColSpec('WHEN', width: 106),
    ColSpec('FACILITY', flex: 3),
    ColSpec('RATING', width: 112),
    ColSpec('SENTIMENT', width: 130),
    ColSpec('PERSON', flex: 2, hide: ColumnHide.medium),
    ColSpec('COMMENT', flex: 5),
  ];

  bool get _hasActiveFilters {
    return _search.text.trim().isNotEmpty ||
        _facilityName != 'All facilities' ||
        _rating != _RatingFilter.all ||
        _sentiment != _SentimentFilter.all ||
        _analysisStatus != _AnalysisStatusFilter.all ||
        _topic != null ||
        _date != _DateFilter.all ||
        _needsReviewOnly ||
        _sort != FeedbackSort.newest;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _apply(AppState state) {
    (int?, int?) ratingRange() {
      return switch (_rating) {
        _RatingFilter.all => (null, null),
        _RatingFilter.five => (5, 5),
        _RatingFilter.four => (4, 4),
        _RatingFilter.three => (3, 3),
        _RatingFilter.two => (2, 2),
        _RatingFilter.one => (1, 1),
        _RatingFilter.low => (1, 2),
      };
    }

    final (minRating, maxRating) = ratingRange();

    final facilityId = _facilityName == 'All facilities'
        ? null
        : state.facilities
              .where((facility) => facility.name == _facilityName)
              .map((facility) => facility.id)
              .firstOrNull;

    final (from, to) = _dateRange();

    state.setFeedbackQuery(
      FeedbackQuery(
        search: _search.text.trim(),
        facilityId: facilityId,
        minRating: minRating,
        maxRating: maxRating,
        from: from,
        to: to,
        sentiment: _sentiment.sentiment,
        topic: _topic,
        analysisStatus: _analysisStatus.status,
        needsReview: _needsReviewOnly ? true : null,
        sort: _sort,
      ),
    );
  }

  (DateTime?, DateTime?) _dateRange() {
    final now = campusInstant(campusNow());
    return switch (_date) {
      _DateFilter.all => (null, null),
      _DateFilter.sevenDays => (now.subtract(const Duration(days: 7)), now),
      _DateFilter.thirtyDays => (now.subtract(const Duration(days: 30)), now),
      _DateFilter.semester => (
        campusInstant(DateTime(now.month >= 8 ? now.year : now.year - 1, 8, 1)),
        now,
      ),
    };
  }

  List<String> get _topicItems => [
    'All topics',
    for (final topic in FeedbackTopic.values) topic.label,
  ];

  FeedbackTopic? _topicFromLabel(String value) {
    if (value == 'All topics') return null;
    return FeedbackTopic.values
        .where((topic) => topic.label == value)
        .firstOrNull;
  }

  void _resetFilters(AppState state) {
    _search.clear();

    setState(() {
      _facilityName = 'All facilities';
      _rating = _RatingFilter.all;
      _sentiment = _SentimentFilter.all;
      _analysisStatus = _AnalysisStatusFilter.all;
      _topic = null;
      _date = _DateFilter.all;
      _needsReviewOnly = false;
      _sort = FeedbackSort.newest;
    });

    _apply(state);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppScope.of(context),
      builder: (context, _) {
        final state = AppScope.of(context);

        final facilityNames = <String>[
          'All facilities',
          for (final facility in state.facilities) facility.name,
        ];

        return LayoutBuilder(
          builder: (context, viewport) {
            final screenWidth = viewport.maxWidth;

            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: screenWidth < 600 ? 24 : 32),
              child: Padding(
                padding: SR.pageInsets(screenWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrPageHeader(
                      title: 'Feedback',
                      description:
                          'View reviews submitted by users after completed reservations.',
                    ),

                    SizedBox(height: screenWidth < 600 ? 18 : 24),

                    _FeedbackSummary(
                      summary: state.feedbackSummaryData,
                      analytics: state.feedbackSentimentAnalyticsData,
                      loading: state.feedbackAnalyticsLoading,
                    ),

                    SizedBox(height: screenWidth < 600 ? 14 : 18),

                    _SentimentInsights(
                      analytics: state.feedbackSentimentAnalyticsData,
                      loading: state.feedbackAnalyticsLoading,
                      error: state.feedbackAnalyticsError,
                      onRetry: () {
                        state.refreshFeedback();
                      },
                    ),

                    SizedBox(height: screenWidth < 600 ? 14 : 18),

                    _buildFilters(
                      context: context,
                      state: state,
                      facilityNames: facilityNames,
                    ),

                    SizedBox(height: screenWidth < 600 ? 20 : 24),

                    _buildResultsHeader(context, state),

                    const SizedBox(height: 10),

                    _buildFeedbackContent(context, state),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFilters({
    required BuildContext context,
    required AppState state,
    required List<String> facilityNames,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          final mobile = width < 680;
          final tablet = width >= 680 && width < 1050;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text('Filters', style: sans(13, w: 600)),
                  const Spacer(),
                  if (_hasActiveFilters)
                    TextButton.icon(
                      onPressed: () {
                        _resetFilters(state);
                      },
                      icon: const Icon(Icons.restart_alt_rounded, size: 17),
                      label: const Text('Reset'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 12),

              if (mobile)
                _buildMobileFilters(state, facilityNames)
              else
                _buildDesktopFilters(
                  state: state,
                  facilityNames: facilityNames,
                  tablet: tablet,
                  availableWidth: width,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobileFilters(AppState state, List<String> facilityNames) {
    final topicLabel = _topic?.label ?? 'All topics';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilterSearch(
          controller: _search,
          placeholder: 'Search feedback',
          onChanged: (_) {
            setState(() {});
            _apply(state);
          },
        ),

        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilterSelect(
                value: _facilityName,
                items: facilityNames,
                semanticLabel: 'Filter by facility',
                onChanged: (value) {
                  setState(() {
                    _facilityName = value;
                  });

                  _apply(state);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilterSelect(
                value: _ratingLabels[_rating]!,
                items: _ratingLabels.values.toList(),
                semanticLabel: 'Filter by rating',
                onChanged: (value) {
                  final selected = _ratingLabels.entries
                      .firstWhere((entry) => entry.value == value)
                      .key;

                  setState(() {
                    _rating = selected;
                  });

                  _apply(state);
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        Row(
          children: [
            Expanded(
              child: FilterSelect(
                value: _sentiment.label,
                items: [
                  for (final filter in _SentimentFilter.values) filter.label,
                ],
                semanticLabel: 'Filter by sentiment',
                onChanged: (value) {
                  final selected = _SentimentFilter.values.firstWhere(
                    (filter) => filter.label == value,
                  );
                  setState(() {
                    _sentiment = selected;
                  });
                  _apply(state);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilterSelect(
                value: _date.label,
                items: [for (final filter in _DateFilter.values) filter.label],
                semanticLabel: 'Filter by date',
                onChanged: (value) {
                  final selected = _DateFilter.values.firstWhere(
                    (filter) => filter.label == value,
                  );
                  setState(() {
                    _date = selected;
                  });
                  _apply(state);
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        Row(
          children: [
            Expanded(
              child: FilterSelect(
                value: _analysisStatus.label,
                items: [
                  for (final filter in _AnalysisStatusFilter.values)
                    filter.label,
                ],
                semanticLabel: 'Filter by analysis status',
                onChanged: (value) {
                  final selected = _AnalysisStatusFilter.values.firstWhere(
                    (filter) => filter.label == value,
                  );
                  setState(() {
                    _analysisStatus = selected;
                  });
                  _apply(state);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilterSelect(
                value: _sortLabels[_sort]!,
                items: _sortLabels.values.toList(),
                semanticLabel: 'Sort feedback',
                onChanged: (value) {
                  final selected = _sortLabels.entries
                      .firstWhere((entry) => entry.value == value)
                      .key;

                  setState(() {
                    _sort = selected;
                  });

                  _apply(state);
                },
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        Row(
          children: [
            Expanded(
              child: FilterSelect(
                value: topicLabel,
                items: _topicItems,
                semanticLabel: 'Filter by feedback topic',
                onChanged: (value) {
                  setState(() {
                    _topic = _topicFromLabel(value);
                  });
                  _apply(state);
                },
              ),
            ),
            const SizedBox(width: 8),
            _NeedsReviewToggle(
              selected: _needsReviewOnly,
              onChanged: (value) {
                setState(() {
                  _needsReviewOnly = value;
                });
                _apply(state);
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDesktopFilters({
    required AppState state,
    required List<String> facilityNames,
    required bool tablet,
    required double availableWidth,
  }) {
    const gap = 10.0;

    final tabletItemWidth = (availableWidth - gap) / 2;
    final topicLabel = _topic?.label ?? 'All topics';

    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        SizedBox(
          width: tablet ? tabletItemWidth : 300,
          child: FilterSearch(
            controller: _search,
            placeholder: 'Search feedback',
            onChanged: (_) {
              setState(() {});
              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 220,
          child: FilterSelect(
            value: _facilityName,
            items: facilityNames,
            semanticLabel: 'Filter by facility',
            onChanged: (value) {
              setState(() {
                _facilityName = value;
              });

              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 180,
          child: FilterSelect(
            value: _ratingLabels[_rating]!,
            items: _ratingLabels.values.toList(),
            semanticLabel: 'Filter by rating',
            onChanged: (value) {
              final selected = _ratingLabels.entries
                  .firstWhere((entry) => entry.value == value)
                  .key;

              setState(() {
                _rating = selected;
              });

              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 180,
          child: FilterSelect(
            value: _sentiment.label,
            items: [for (final filter in _SentimentFilter.values) filter.label],
            semanticLabel: 'Filter by sentiment',
            onChanged: (value) {
              final selected = _SentimentFilter.values.firstWhere(
                (filter) => filter.label == value,
              );

              setState(() {
                _sentiment = selected;
              });

              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 160,
          child: FilterSelect(
            value: _date.label,
            items: [for (final filter in _DateFilter.values) filter.label],
            semanticLabel: 'Filter by date',
            onChanged: (value) {
              final selected = _DateFilter.values.firstWhere(
                (filter) => filter.label == value,
              );

              setState(() {
                _date = selected;
              });

              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 190,
          child: FilterSelect(
            value: _analysisStatus.label,
            items: [
              for (final filter in _AnalysisStatusFilter.values) filter.label,
            ],
            semanticLabel: 'Filter by analysis status',
            onChanged: (value) {
              final selected = _AnalysisStatusFilter.values.firstWhere(
                (filter) => filter.label == value,
              );

              setState(() {
                _analysisStatus = selected;
              });

              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 190,
          child: FilterSelect(
            value: topicLabel,
            items: _topicItems,
            semanticLabel: 'Filter by feedback topic',
            onChanged: (value) {
              setState(() {
                _topic = _topicFromLabel(value);
              });

              _apply(state);
            },
          ),
        ),
        SizedBox(
          width: tablet ? tabletItemWidth : 190,
          child: FilterSelect(
            value: _sortLabels[_sort]!,
            items: _sortLabels.values.toList(),
            semanticLabel: 'Sort feedback',
            onChanged: (value) {
              final selected = _sortLabels.entries
                  .firstWhere((entry) => entry.value == value)
                  .key;

              setState(() {
                _sort = selected;
              });

              _apply(state);
            },
          ),
        ),
        _NeedsReviewToggle(
          selected: _needsReviewOnly,
          onChanged: (value) {
            setState(() {
              _needsReviewOnly = value;
            });

            _apply(state);
          },
        ),
      ],
    );
  }

  Widget _buildResultsHeader(BuildContext context, AppState state) {
    final c = context.srColors;
    final scheme = Theme.of(context).colorScheme;

    final total = state.feedbackEntriesTotal;

    return Row(
      children: [
        Expanded(child: Text('Reviews', style: sans(14, w: 600))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            '$total ${total == 1 ? 'review' : 'reviews'}',
            style: sans(11.5, w: 500, color: c.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _buildFeedbackContent(BuildContext context, AppState state) {
    if (state.feedbackLoading && state.feedbackEntries.isEmpty) {
      return _FeedbackLoadingState(columns: _columns);
    }

    if (state.feedbackError != null && state.feedbackEntries.isEmpty) {
      return _FeedbackErrorState(
        message: state.feedbackError!,
        onRetry: () {
          state.refreshFeedback();
        },
      );
    }

    if (state.feedbackEntries.isEmpty) {
      return const _FeedbackEmptyState();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return _buildMobileReviews(context, state);
        }

        return _buildDesktopReviews(context, state);
      },
    );
  }

  Widget _buildMobileReviews(BuildContext context, AppState state) {
    return Column(
      children: [
        for (int i = 0; i < state.feedbackEntries.length; i++) ...[
          _MobileFeedbackCard(
            entry: state.feedbackEntries[i],
            onTap: () =>
                _showFeedbackDetails(context, state, state.feedbackEntries[i]),
          ),
          if (i != state.feedbackEntries.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildDesktopReviews(BuildContext context, AppState state) {
    return RecordTable(
      columns: _columns,
      children: [
        for (final entry in state.feedbackEntries) _desktopRow(context, entry),
      ],
    );
  }

  Widget _desktopRow(BuildContext context, FeedbackEntry entry) {
    final feedback = entry.feedback;

    return RecordRow(
      columns: _columns,
      onTap: () => _showFeedbackDetails(context, AppScope.of(context), entry),
      compactChild: _MobileFeedbackCard(
        entry: entry,
        onTap: () => _showFeedbackDetails(context, AppScope.of(context), entry),
      ),
      cells: [
        Text(
          _shortDate(feedback.createdAt),
          style: mono(11, color: context.srColors.textMuted),
        ),
        Text(
          feedback.facilityName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sans(12.5, w: 500),
        ),
        SrRatingStars(
          average: feedback.rating.toDouble(),
          count: 1,
          dense: true,
          showCount: false,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _SentimentBadge(analysis: feedback.sentimentAnalysis),
        ),
        Text(
          entry.reviewerName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sans(12.5),
        ),
        Text(
          feedback.comment.trim().isEmpty ? '—' : feedback.comment,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: sans(
            12.5,
            height: 1.45,
            color: context.srColors.textSecondary,
          ),
        ),
      ],
    );
  }

  static String _shortDate(DateTime value) {
    return '${value.month}/${value.day}/${value.year}';
  }

  void _showFeedbackDetails(
    BuildContext context,
    AppState state,
    FeedbackEntry entry,
  ) {
    final status = entry.feedback.sentimentStatus;
    final canQueueAnalysis =
        entry.feedback.comment.trim().isNotEmpty &&
        (status == SentimentAnalysisStatus.failed ||
            status == SentimentAnalysisStatus.notAnalyzed);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SrAdaptiveDialog(
        maxWidth: 620,
        maxHeight: 720,
        child: _FeedbackDetailDialog(
          entry: entry,
          retrying: state.feedbackSentimentRetrying.contains(entry.feedback.id),
          onRetry: canQueueAnalysis
              ? () {
                  Navigator.of(dialogContext).pop();
                  state.retryFeedbackSentiment(entry.feedback.id);
                }
              : null,
        ),
      ),
    );
  }
}

class _FeedbackSummary extends StatelessWidget {
  const _FeedbackSummary({
    required this.summary,
    required this.analytics,
    required this.loading,
  });

  final FeedbackSummary summary;
  final FeedbackSentimentAnalytics analytics;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        const gap = 10.0;

        final columns = width >= 900 ? 4 : 2;

        final cardWidth = (width - ((columns - 1) * gap)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(
              width: cardWidth,
              child: _SummaryCard(
                icon: Icons.star_outline_rounded,
                label: 'Average rating',
                value: summary.average == null
                    ? '—'
                    : summary.average!.toStringAsFixed(1),
                supportingText: summary.average == null
                    ? 'No ratings yet'
                    : 'Out of 5',
                tone: _SummaryTone.primary,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _SummaryCard(
                icon: Icons.rate_review_outlined,
                label: 'Total reviews',
                value: '${summary.total}',
                supportingText: 'All submitted reviews',
                tone: _SummaryTone.neutral,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _SummaryCard(
                icon: Icons.sentiment_satisfied_alt_rounded,
                label: 'Positive sentiment',
                value: loading ? '...' : _percentText(analytics.positiveShare),
                supportingText:
                    '${analytics.percentageDenominator} classified reviews',
                tone: _SummaryTone.success,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _SummaryCard(
                icon: Icons.flag_outlined,
                label: 'Needs review',
                value: loading ? '...' : '${analytics.needsReview}',
                supportingText: 'Low rating or negative text',
                tone: analytics.needsReview > 0
                    ? _SummaryTone.error
                    : _SummaryTone.neutral,
              ),
            ),
          ],
        );
      },
    );
  }

  static String _percentText(double? value) =>
      value == null ? '—' : '${(value * 100).round()}%';
}

enum _SummaryTone { primary, success, error, neutral }

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.supportingText,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final String supportingText;
  final _SummaryTone tone;

  Color _toneColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return switch (tone) {
      _SummaryTone.primary => scheme.primary,
      _SummaryTone.success => const Color(0xFF2E7D32),
      _SummaryTone.error => scheme.error,
      _SummaryTone.neutral => scheme.onSurfaceVariant,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = context.srColors;

    final accent = _toneColor(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 116),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: accent),
          ),

          const SizedBox(height: 12),

          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(22, w: 700),
          ),

          const SizedBox(height: 2),

          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(11.5, w: 600, color: c.textSecondary),
          ),

          const SizedBox(height: 2),

          Text(
            supportingText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(10.5, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _SentimentInsights extends StatelessWidget {
  const _SentimentInsights({
    required this.analytics,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final FeedbackSentimentAnalytics analytics;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final hasData = analytics.hasAnyAnalysis || analytics.totalFeedback > 0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Sentiment analytics', style: sans(13, w: 650)),
              ),
              if (loading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: SR.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Sentiment is automatically estimated from the written feedback and may not reflect the user’s intended meaning. Read the original feedback before acting.',
            style: sans(11.5, height: 1.45, color: c.textSecondary),
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: c.amberIcon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    style: sans(11.5, color: c.amberTitle, height: 1.35),
                  ),
                ),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ],
          if (!hasData && !loading) ...[
            const SizedBox(height: 14),
            Text(
              'Sentiment analytics will appear after written comments are processed.',
              style: sans(12, color: c.textMuted),
            ),
          ] else ...[
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 920;
                final distribution = _SentimentDistribution(
                  analytics: analytics,
                );
                final operations = _AnalysisOperations(analytics: analytics);
                return wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: distribution),
                          const SizedBox(width: 14),
                          Expanded(child: operations),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          distribution,
                          const SizedBox(height: 12),
                          operations,
                        ],
                      );
              },
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 920;
                final facilities = _FacilitySentimentPanel(
                  analytics: analytics,
                );
                final complaints = _ComplaintTopicPanel(analytics: analytics);
                return wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: facilities),
                          const SizedBox(width: 14),
                          Expanded(child: complaints),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          facilities,
                          const SizedBox(height: 12),
                          complaints,
                        ],
                      );
              },
            ),
            if (analytics.hasRenderableTrend) ...[
              const SizedBox(height: 14),
              _SentimentTrendPanel(analytics: analytics),
            ],
          ],
        ],
      ),
    );
  }
}

class _SentimentDistribution extends StatelessWidget {
  const _SentimentDistribution({required this.analytics});

  final FeedbackSentimentAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    return _InsightBlock(
      title: 'Distribution',
      subtitle: analytics.percentageDenominator == 0
          ? 'No classified written reviews yet'
          : '${analytics.percentageDenominator} classified reviews',
      child: Column(
        children: [
          _SentimentBar(
            label: SentimentLabel.positive.label,
            count: analytics.positive,
            share: analytics.shareFor(analytics.positive),
            tone: SentimentLabel.positive.tone,
          ),
          _SentimentBar(
            label: SentimentLabel.neutral.label,
            count: analytics.neutral,
            share: analytics.shareFor(analytics.neutral),
            tone: SentimentLabel.neutral.tone,
          ),
          _SentimentBar(
            label: SentimentLabel.negative.label,
            count: analytics.negative,
            share: analytics.shareFor(analytics.negative),
            tone: SentimentLabel.negative.tone,
          ),
          _SentimentBar(
            label: SentimentLabel.mixed.label,
            count: analytics.mixed,
            share: analytics.shareFor(analytics.mixed),
            tone: SentimentLabel.mixed.tone,
          ),
        ],
      ),
    );
  }
}

class _SentimentBar extends StatelessWidget {
  const _SentimentBar({
    required this.label,
    required this.count,
    required this.share,
    required this.tone,
  });

  final String label;
  final int count;
  final double? share;
  final SrTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final value = share ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: sans(11.5, color: c.textSecondary)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 7,
                backgroundColor: c.dividerSoft,
                color: tone.solid,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              share == null ? '$count' : '${(value * 100).round()}% · $count',
              textAlign: TextAlign.right,
              style: mono(10.5, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalysisOperations extends StatelessWidget {
  const _AnalysisOperations({required this.analytics});

  final FeedbackSentimentAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    return _InsightBlock(
      title: 'Coverage',
      subtitle:
          '${analytics.classifiedFeedback} of ${analytics.writtenFeedback} written reviews analyzed',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _MetricChip(label: 'Pending', count: analytics.pending),
          _MetricChip(label: 'Processing', count: analytics.processing),
          _MetricChip(
            label: 'Unavailable',
            count: analytics.failed,
            tone: analytics.failed > 0 ? SrTone.warning : SrTone.neutral,
          ),
          _MetricChip(label: 'No comment', count: analytics.skipped),
          _MetricChip(label: 'Not analyzed', count: analytics.notAnalyzed),
          _MetricChip(
            label: 'Mismatches',
            count: analytics.ratingMismatch,
            tone: analytics.ratingMismatch > 0 ? SrTone.info : SrTone.neutral,
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.count,
    this.tone = SrTone.neutral,
  });

  final String label;
  final int count;
  final SrTone tone;

  @override
  Widget build(BuildContext context) =>
      SrStatusChip(label: '$label $count', tone: tone, dense: true);
}

class _FacilitySentimentPanel extends StatelessWidget {
  const _FacilitySentimentPanel({required this.analytics});

  final FeedbackSentimentAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return _InsightBlock(
      title: 'Facility attention',
      subtitle: 'Requires at least 3 classified reviews',
      child: analytics.facilities.isEmpty
          ? Text(
              'Not enough facility data yet.',
              style: sans(12, color: c.textMuted),
            )
          : Column(
              children: [
                for (final facility in analytics.facilities.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            facility.facilityName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(12, w: 550),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${(facility.negativeShare * 100).round()}% neg · ${facility.classified}',
                          style: mono(10.5, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ComplaintTopicPanel extends StatelessWidget {
  const _ComplaintTopicPanel({required this.analytics});

  final FeedbackSentimentAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return _InsightBlock(
      title: 'Common complaints',
      subtitle: 'Negative aspect topics only',
      child: analytics.complaints.isEmpty
          ? Text(
              'No repeated complaint topics yet.',
              style: sans(12, color: c.textMuted),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final complaint in analytics.complaints)
                  SrStatusChip(
                    label:
                        '${complaint.topic.label} ${complaint.count} · ${complaint.facilityCount} facilities',
                    tone: SrTone.warning,
                    dense: true,
                  ),
              ],
            ),
    );
  }
}

class _SentimentTrendPanel extends StatelessWidget {
  const _SentimentTrendPanel({required this.analytics});

  final FeedbackSentimentAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final recent = analytics.trend.length > 6
        ? analytics.trend.skip(analytics.trend.length - 6).toList()
        : analytics.trend;
    return _InsightBlock(
      title: 'Recent trend',
      subtitle: 'Bucketed by ${analytics.trendBucket}',
      child: Column(
        children: [
          for (final point in recent)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: Text(
                      _shortTrendDate(point.bucketStart),
                      style: mono(10.5, color: c.textMuted),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${point.positive} positive · ${point.neutral} neutral · ${point.negative} negative · ${point.mixed} mixed',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11.5, color: c.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    point.averageRating == null
                        ? '—'
                        : '${point.averageRating!.toStringAsFixed(1)}★',
                    style: mono(10.5, color: c.textMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _shortTrendDate(DateTime value) =>
      '${value.month}/${value.day}/${value.year}';
}

class _InsightBlock extends StatelessWidget {
  const _InsightBlock({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surfaceSubtle,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: sans(12.5, w: 650)),
          const SizedBox(height: 2),
          Text(subtitle, style: sans(10.8, color: c.textMuted)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _NeedsReviewToggle extends StatelessWidget {
  const _NeedsReviewToggle({required this.selected, required this.onChanged});

  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => FilterPill(
    label: 'Needs review',
    selected: selected,
    onTap: () => onChanged(!selected),
  );
}

class _SentimentBadge extends StatelessWidget {
  const _SentimentBadge({required this.analysis, this.dense = true});

  final FeedbackSentimentAnalysis? analysis;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final status = analysis?.status ?? SentimentAnalysisStatus.notAnalyzed;
    final sentiment = analysis?.sentiment;

    if (status == SentimentAnalysisStatus.completed && sentiment != null) {
      return SrStatusChip(
        label: sentiment.label,
        tone: sentiment.tone,
        icon: _sentimentIcon(sentiment),
        dense: dense,
      );
    }

    return SrStatusChip(
      label: status.label,
      tone: status.tone,
      icon: _statusIcon(status),
      dense: dense,
    );
  }

  IconData _sentimentIcon(SentimentLabel sentiment) => switch (sentiment) {
    SentimentLabel.positive => Icons.sentiment_satisfied_alt_rounded,
    SentimentLabel.neutral => Icons.sentiment_neutral_rounded,
    SentimentLabel.negative => Icons.sentiment_dissatisfied_rounded,
    SentimentLabel.mixed => Icons.compare_arrows_rounded,
    SentimentLabel.unknown => Icons.help_outline_rounded,
  };

  IconData _statusIcon(SentimentAnalysisStatus status) => switch (status) {
    SentimentAnalysisStatus.notAnalyzed => Icons.pending_outlined,
    SentimentAnalysisStatus.pending => Icons.schedule_rounded,
    SentimentAnalysisStatus.processing => Icons.autorenew_rounded,
    SentimentAnalysisStatus.completed => Icons.check_circle_outline_rounded,
    SentimentAnalysisStatus.failed => Icons.refresh_rounded,
    SentimentAnalysisStatus.skipped => Icons.notes_rounded,
  };
}

class _FeedbackDetailDialog extends StatelessWidget {
  const _FeedbackDetailDialog({
    required this.entry,
    required this.retrying,
    required this.onRetry,
  });

  final FeedbackEntry entry;
  final bool retrying;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final feedback = entry.feedback;
    final analysis = feedback.sentimentAnalysis;
    final c = context.srColors;
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 20,
            compact ? 8 : 18,
            compact ? 8 : 12,
            10,
          ),
          child: Row(
            children: [
              Expanded(child: Text('Feedback details', style: SrType.title())),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(compact ? 16 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _RatingBadge(rating: feedback.rating),
                    _SentimentBadge(analysis: analysis, dense: false),
                    if (feedback.needsReview)
                      const SrStatusChip(
                        label: 'Needs review',
                        tone: SrTone.warning,
                        icon: Icons.flag_outlined,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _DetailSection(
                  title: feedback.facilityName,
                  child: Text(
                    feedback.comment.trim().isEmpty
                        ? 'No written comment was submitted.'
                        : feedback.comment,
                    style: sans(13, height: 1.55, color: c.textSecondary),
                  ),
                ),
                const SizedBox(height: 14),
                _DetailSection(
                  title: 'Reservation context',
                  child: Column(
                    children: [
                      _DetailLine('Reviewer', entry.reviewerName),
                      _DetailLine(
                        'Visit date',
                        entry.reservationStartsAt == null
                            ? 'Not available'
                            : _MobileFeedbackCard.formatDate(
                                entry.reservationStartsAt!,
                              ),
                      ),
                      _DetailLine(
                        'Feedback date',
                        _MobileFeedbackCard.formatDate(feedback.createdAt),
                      ),
                      if (entry.pricingAudience.trim().isNotEmpty)
                        _DetailLine(
                          'Renter type',
                          entry.pricingAudience.replaceAll('_', ' '),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _DetailSection(
                  title: 'Ratings',
                  child: Column(
                    children: [
                      _DetailLine('Overall', '${feedback.rating} of 5'),
                      _optionalRating(
                        'Cleanliness',
                        feedback.cleanlinessRating,
                      ),
                      _optionalRating(
                        'Facility condition',
                        feedback.conditionRating,
                      ),
                      _optionalRating('Equipment', feedback.equipmentRating),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _DetailSection(
                  title: 'Sentiment analysis',
                  child: _AnalysisDetails(
                    feedback: feedback,
                    analysis: analysis,
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        Padding(
          padding: EdgeInsets.all(compact ? 16 : 18),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Close'),
              ),
              if (onRetry != null)
                FilledButton.icon(
                  onPressed: retrying ? null : onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(retrying ? 'Queuing...' : 'Retry analysis'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _optionalRating(String label, int? value) =>
      _DetailLine(label, value == null ? 'Not rated' : '$value of 5');
}

class _AnalysisDetails extends StatelessWidget {
  const _AnalysisDetails({required this.feedback, required this.analysis});

  final ReservationFeedback feedback;
  final FeedbackSentimentAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final current = analysis;
    final status = current?.status ?? SentimentAnalysisStatus.notAnalyzed;

    if (status == SentimentAnalysisStatus.skipped) {
      return Text(
        'No written comment to analyze.',
        style: sans(12, color: c.textMuted),
      );
    }
    if (current == null) {
      return Text(
        'Analysis has not been queued for this historical review.',
        style: sans(12, color: c.textMuted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SentimentBadge(analysis: current, dense: false),
            if (current.isLowConfidence)
              const SrStatusChip(
                label: 'Low confidence',
                tone: SrTone.warning,
                icon: Icons.info_outline_rounded,
              ),
            if (feedback.ratingSentimentMismatch)
              const SrStatusChip(
                label: 'Rating and text differ',
                tone: SrTone.info,
                icon: Icons.compare_arrows_rounded,
              ),
          ],
        ),
        if (current.confidence != null) ...[
          const SizedBox(height: 10),
          _DetailLine('Confidence', '${(current.confidence! * 100).round()}%'),
        ],
        _DetailLine('Status', status.label),
        if (current.analyzedAt != null)
          _DetailLine(
            'Analyzed',
            _MobileFeedbackCard.formatDate(current.analyzedAt!),
          ),
        if ((current.model ?? '').isNotEmpty)
          _DetailLine('Model', current.model!),
        if (current.lastErrorCode != null)
          _DetailLine('Last error', current.lastErrorCode!),
        if (current.topics.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final topic in current.topics)
                SrStatusChip(
                  label: '${topic.topic.label}: ${topic.sentiment.label}',
                  tone: topic.sentiment.tone,
                  dense: true,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.srColors.surfaceSubtle,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: sans(12.5, w: 650)),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: sans(11.5, color: c.textMuted)),
          ),
          Expanded(
            child: Text(
              value,
              style: sans(11.8, w: 500, color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileFeedbackCard extends StatelessWidget {
  const _MobileFeedbackCard({required this.entry, this.onTap});

  final FeedbackEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = context.srColors;

    final feedback = entry.feedback;
    final hasComment = feedback.comment.trim().isNotEmpty;

    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      feedback.facilityName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: sans(14, w: 650),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatDate(feedback.createdAt),
                      style: sans(11, color: c.textMuted),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _RatingBadge(rating: feedback.rating),
                  const SizedBox(height: 6),
                  _SentimentBadge(analysis: feedback.sentimentAnalysis),
                ],
              ),
            ],
          ),

          const SizedBox(height: 13),

          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.person_outline_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
              ),

              const SizedBox(width: 9),

              Expanded(
                child: Text(
                  entry.reviewerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(12.5, w: 550),
                ),
              ),
            ],
          ),

          if (hasComment) ...[
            const SizedBox(height: 13),

            Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),

            const SizedBox(height: 12),

            Text(
              feedback.comment,
              style: sans(12.5, height: 1.5, color: c.textSecondary),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
    );
  }

  static String formatDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return '${months[value.month - 1]} '
        '${value.day}, ${value.year}';
  }
}

class _RatingBadge extends StatelessWidget {
  const _RatingBadge({required this.rating});

  final int rating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final Color foreground;

    if (rating >= 4) {
      foreground = const Color(0xFF2E7D32);
    } else if (rating <= 2) {
      foreground = scheme.error;
    } else {
      foreground = scheme.onSurfaceVariant;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 15, color: foreground),
          const SizedBox(width: 4),
          Text('$rating.0', style: sans(11.5, w: 650, color: foreground)),
        ],
      ),
    );
  }
}

class _FeedbackEmptyState extends StatelessWidget {
  const _FeedbackEmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = context.srColors;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 190),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.rate_review_outlined,
              size: 23,
              color: scheme.primary,
            ),
          ),

          const SizedBox(height: 14),

          Text(
            'No feedback found',
            textAlign: TextAlign.center,
            style: sans(14, w: 600),
          ),

          const SizedBox(height: 6),

          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              'Reviews will appear here after users rate '
              'their completed reservations.',
              textAlign: TextAlign.center,
              style: sans(12, height: 1.45, color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedbackErrorState extends StatelessWidget {
  const _FeedbackErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = context.srColors;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.error.withValues(alpha: 0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.error.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.error_outline_rounded,
              color: scheme.error,
              size: 23,
            ),
          ),

          const SizedBox(height: 14),

          Text(
            'Unable to load feedback',
            textAlign: TextAlign.center,
            style: sans(14, w: 600),
          ),

          const SizedBox(height: 6),

          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: sans(12, height: 1.45, color: c.textSecondary),
            ),
          ),

          const SizedBox(height: 16),

          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _FeedbackLoadingState extends StatelessWidget {
  const _FeedbackLoadingState({required this.columns});

  final List<ColSpec> columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return const Column(
            children: [
              _MobileFeedbackSkeleton(),
              SizedBox(height: 10),
              _MobileFeedbackSkeleton(),
              SizedBox(height: 10),
              _MobileFeedbackSkeleton(),
              SizedBox(height: 10),
              _MobileFeedbackSkeleton(),
            ],
          );
        }

        return Column(
          children: [
            for (var i = 0; i < 6; i++)
              SkeletonRow(columns: columns, leadWidth: 30),
          ],
        );
      },
    );
  }
}

class _MobileFeedbackSkeleton extends StatelessWidget {
  const _MobileFeedbackSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget skeleton({required double width, required double height}) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: skeleton(width: double.infinity, height: 14)),
              const SizedBox(width: 28),
              skeleton(width: 54, height: 26),
            ],
          ),

          const SizedBox(height: 8),

          skeleton(width: 90, height: 10),

          const SizedBox(height: 18),

          skeleton(width: 130, height: 12),

          const SizedBox(height: 16),

          skeleton(width: double.infinity, height: 11),

          const SizedBox(height: 7),

          skeleton(width: 210, height: 11),
        ],
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    return isEmpty ? null : first;
  }
}
