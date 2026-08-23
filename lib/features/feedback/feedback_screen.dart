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
  final _search = TextEditingController();
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _apply(AppState state) {
    (int?, int?) ratingRange() => switch (_rating) {
      _RatingFilter.all => (null, null),
      _RatingFilter.five => (5, 5),
      _RatingFilter.four => (4, 4),
      _RatingFilter.three => (3, 3),
      _RatingFilter.two => (2, 2),
      _RatingFilter.one => (1, 1),
      _RatingFilter.low => (1, 2),
    };
    final (min, max) = ratingRange();
    final facility = _facilityName == 'All facilities'
        ? null
        : state.facilities
              .where((f) => f.name == _facilityName)
              .map((f) => f.id)
              .firstOrNull;
    state.setFeedbackQuery(
      FeedbackQuery(
        search: _search.text,
        facilityId: facility,
        minRating: min,
        maxRating: max,
        sort: _sort,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppScope.of(context),
      builder: (context, _) {
        final state = AppScope.of(context);
        final facilityNames = [
          'All facilities',
          for (final f in state.facilities) f.name,
        ];
        return Padding(
          padding: SR.pageInsets(MediaQuery.sizeOf(context).width),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SrPageHeader(
                title: 'Feedback',
                description: 'Reviews left by users after a completed reservation.',
              ),
              const SizedBox(height: 16),
              _summary(context, state.feedbackSummaryData),
              const SizedBox(height: 16),
              FilterBar(
                count: '${state.feedbackEntriesTotal} shown',
                children: [
                  FilterSearch(
                    controller: _search,
                    placeholder: 'Search feedback',
                    onChanged: (_) => _apply(state),
                  ),
                  FilterSelect(
                    value: _facilityName,
                    items: facilityNames,
                    semanticLabel: 'Filter by facility',
                    onChanged: (v) {
                      setState(() => _facilityName = v);
                      _apply(state);
                    },
                  ),
                  FilterSelect(
                    value: _ratingLabels[_rating]!,
                    items: _ratingLabels.values.toList(),
                    semanticLabel: 'Filter by rating',
                    onChanged: (v) {
                      setState(
                        () => _rating = _ratingLabels.entries
                            .firstWhere((e) => e.value == v)
                            .key,
                      );
                      _apply(state);
                    },
                  ),
                  FilterSelect(
                    value: _sortLabels[_sort]!,
                    items: _sortLabels.values.toList(),
                    semanticLabel: 'Sort',
                    onChanged: (v) {
                      setState(
                        () => _sort = _sortLabels.entries
                            .firstWhere((e) => e.value == v)
                            .key,
                      );
                      _apply(state);
                    },
                  ),
                ],
              ),
              Expanded(child: _list(context, state)),
            ],
          ),
        );
      },
    );
  }

  Widget _summary(BuildContext context, FeedbackSummary summary) => Row(
    children: [
      Expanded(
        child: SrStat(
          label: 'AVERAGE',
          value: summary.average == null ? '—' : summary.average!.toStringAsFixed(1),
        ),
      ),
      Expanded(child: SrStat(label: 'TOTAL REVIEWS', value: '${summary.total}')),
      Expanded(
        child: SrStat(
          label: '5-STAR',
          value: '${summary.fiveStar}',
          tone: SrTone.success,
        ),
      ),
      Expanded(
        child: SrStat(
          label: 'LOW-RATED',
          value: '${summary.lowRated}',
          tone: summary.lowRated > 0 ? SrTone.error : SrTone.neutral,
        ),
      ),
    ],
  );

  static const _columns = <ColSpec>[
    ColSpec('WHEN', width: 106),
    ColSpec('FACILITY', flex: 3),
    ColSpec('RATING', width: 96),
    ColSpec('PERSON', flex: 2, hide: ColumnHide.medium),
    ColSpec('COMMENT', flex: 5),
  ];

  Widget _list(BuildContext context, AppState state) {
    if (state.feedbackLoading && state.feedbackEntries.isEmpty) {
      return ListView(
        children: [
          for (var i = 0; i < 6; i++)
            const SkeletonRow(columns: _columns, leadWidth: 30),
        ],
      );
    }
    if (state.feedbackError != null && state.feedbackEntries.isEmpty) {
      return SrErrorState(
        message: state.feedbackError!,
        onRetry: () => state.refreshFeedback(),
      );
    }
    if (state.feedbackEntries.isEmpty) {
      return const ListEmptyState(
        icon: Icons.reviews_rounded,
        title: 'No feedback yet',
        body: 'Reviews will appear here once users start rating their '
            'completed reservations.',
      );
    }
    return SingleChildScrollView(
      child: RecordTable(
        columns: _columns,
        children: [
          for (final entry in state.feedbackEntries) _row(context, entry),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, FeedbackEntry entry) {
    final f = entry.feedback;
    return RecordRow(
      columns: _columns,
      compactChild: _CompactCard(entry: entry),
      cells: [
        Text(_date(f.createdAt), style: mono(11, color: context.srColors.textMuted)),
        Text(f.facilityName, maxLines: 1, overflow: TextOverflow.ellipsis),
        SrRatingStars(average: f.rating.toDouble(), count: 1, dense: true, showCount: false),
        Text(entry.reviewerName, maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(
          f.comment.isEmpty ? '—' : f.comment,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  static String _date(DateTime value) =>
      '${value.month}/${value.day}/${value.year}';
}

class _CompactCard extends StatelessWidget {
  const _CompactCard({required this.entry});

  final FeedbackEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final f = entry.feedback;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(f.facilityName, style: sans(13.5, w: 600)),
            ),
            SrRatingStars(average: f.rating.toDouble(), count: 1, dense: true, showCount: false),
          ],
        ),
        const SizedBox(height: 3),
        Text(entry.reviewerName, style: SrType.caption(color: c.textMuted)),
        if (f.comment.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(f.comment, style: sans(12, height: 1.4, color: c.textSecondary)),
        ],
      ],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
