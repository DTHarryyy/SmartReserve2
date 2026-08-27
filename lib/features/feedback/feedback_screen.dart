import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/feedback.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_components.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

enum _RatingFilter { all, five, four, three, two, one, low }

class _FeedbackScreenState extends State<FeedbackScreen> {
  final TextEditingController _search = TextEditingController();

  String _facilityName = 'All facilities';
  _RatingFilter _rating = _RatingFilter.all;
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
    ColSpec('PERSON', flex: 2, hide: ColumnHide.medium),
    ColSpec('COMMENT', flex: 5),
  ];

  bool get _hasActiveFilters {
    return _search.text.trim().isNotEmpty ||
        _facilityName != 'All facilities' ||
        _rating != _RatingFilter.all ||
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

    state.setFeedbackQuery(
      FeedbackQuery(
        search: _search.text.trim(),
        facilityId: facilityId,
        minRating: minRating,
        maxRating: maxRating,
        sort: _sort,
      ),
    );
  }

  void _resetFilters(AppState state) {
    _search.clear();

    setState(() {
      _facilityName = 'All facilities';
      _rating = _RatingFilter.all;
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

                    _FeedbackSummary(summary: state.feedbackSummaryData),

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search remains full width.
        FilterSearch(
          controller: _search,
          placeholder: 'Search feedback',
          onChanged: (_) {
            setState(() {});
            _apply(state);
          },
        ),

        const SizedBox(height: 10),

        // Facility + Rating + Sort always stay in one row.
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
              flex: 2,
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

            const SizedBox(width: 8),

            Expanded(
              flex: 2,
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
          return _buildMobileReviews(state);
        }

        return _buildDesktopReviews(context, state);
      },
    );
  }

  Widget _buildMobileReviews(AppState state) {
    return Column(
      children: [
        for (int i = 0; i < state.feedbackEntries.length; i++) ...[
          _MobileFeedbackCard(entry: state.feedbackEntries[i]),
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
      compactChild: _MobileFeedbackCard(entry: entry),
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
}

class _FeedbackSummary extends StatelessWidget {
  const _FeedbackSummary({required this.summary});

  final FeedbackSummary summary;

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
                icon: Icons.sentiment_very_satisfied_rounded,
                label: '5-star reviews',
                value: '${summary.fiveStar}',
                supportingText: 'Excellent ratings',
                tone: _SummaryTone.success,
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _SummaryCard(
                icon: Icons.flag_outlined,
                label: 'Low-rated',
                value: '${summary.lowRated}',
                supportingText: '1–2 star reviews',
                tone: summary.lowRated > 0
                    ? _SummaryTone.error
                    : _SummaryTone.neutral,
              ),
            ),
          ],
        );
      },
    );
  }
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

class _MobileFeedbackCard extends StatelessWidget {
  const _MobileFeedbackCard({required this.entry});

  final FeedbackEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = context.srColors;

    final feedback = entry.feedback;
    final hasComment = feedback.comment.trim().isNotEmpty;

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
                      _formatDate(feedback.createdAt),
                      style: sans(11, color: c.textMuted),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              _RatingBadge(rating: feedback.rating),
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
  }

  static String _formatDate(DateTime value) {
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
