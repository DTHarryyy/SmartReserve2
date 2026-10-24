import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/feedback.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'feedback_screen.dart';

/// Feedback in the console: facility reviews, or ratings of the office's
/// own service.
class FeedbackHub extends StatefulWidget {
  const FeedbackHub({super.key});

  @override
  State<FeedbackHub> createState() => _FeedbackHubState();
}

class _FeedbackHubState extends State<FeedbackHub> {
  var _office = false;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final insets = SR.pageInsets(width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            insets.left,
            SR.space12,
            insets.right,
            0,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SrTabs(
              key: const Key('feedback-hub-tabs'),
              scrollable: true,
              items: const [
                SrTabItem(label: 'Facilities', icon: Icons.apartment_rounded),
                SrTabItem(
                  label: 'Office service',
                  icon: Icons.support_agent_rounded,
                ),
              ],
              selectedIndex: _office ? 1 : 0,
              onSelect: (index) => setState(() => _office = index == 1),
            ),
          ),
        ),
        Expanded(
          child: _office ? const OfficeFeedbackPanel() : const FeedbackScreen(),
        ),
      ],
    );
  }
}

class OfficeFeedbackPanel extends StatelessWidget {
  const OfficeFeedbackPanel({super.key});

  static String _average(double? value) =>
      value == null ? '—' : value.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final summary = state.officeFeedbackSummary;
    return SrScrollView(
      padding: SR.pageInsets(width, bottom: SR.space32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrPageHeader(
            description:
                'How renters rate the reservation office itself — response '
                'time, helpfulness and how clear the process is.',
            actions: [
              SrIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Refresh',
                onPressed: state.refreshOfficeFeedback,
              ),
            ],
          ),
          const SizedBox(height: SR.space16),
          LayoutBuilder(
            builder: (context, constraints) {
              final stats = <(String, String, SrTone)>[
                ('Overall', _average(summary.overall), SrTone.brand),
                (
                  'Response time',
                  _average(summary.responsiveness),
                  SrTone.neutral,
                ),
                ('Helpfulness', _average(summary.helpfulness), SrTone.neutral),
                ('Clarity', _average(summary.clarity), SrTone.neutral),
                ('Ratings', '${summary.count}', SrTone.neutral),
                (
                  'Low (1-2)',
                  '${summary.lowCount}',
                  summary.lowCount > 0 ? SrTone.error : SrTone.neutral,
                ),
              ];
              final columns = constraints.maxWidth >= 860
                  ? 6
                  : constraints.maxWidth >= 520
                  ? 3
                  : 2;
              final tileWidth =
                  (constraints.maxWidth - (columns - 1) * SR.space12) / columns;
              return Wrap(
                spacing: SR.space12,
                runSpacing: SR.space12,
                children: [
                  for (final (label, value, tone) in stats)
                    SizedBox(
                      width: tileWidth,
                      child: SrCard(
                        child: SrStat(label: label, value: value, tone: tone),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: SR.space20),
          if (state.officeFeedbackLoading &&
              state.officeFeedbackEntries.isEmpty)
            const SrLoadingState(message: 'Loading office feedback…')
          else if (state.officeFeedbackError case final error?
              when state.officeFeedbackEntries.isEmpty)
            SrErrorState(
              title: 'Office feedback could not be loaded',
              message: error,
              onRetry: state.refreshOfficeFeedback,
            )
          else if (state.officeFeedbackEntries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: SR.space32),
              child: Text(
                'No office ratings yet. Renters can rate the office from '
                'their Account page or after rating a visit.',
                textAlign: TextAlign.center,
                style: SrType.bodySm(color: context.srColors.muted),
              ),
            )
          else
            for (final entry in state.officeFeedbackEntries) ...[
              _OfficeFeedbackRow(state: state, entry: entry),
              const SizedBox(height: SR.space8),
            ],
        ],
      ),
    );
  }
}

class _OfficeFeedbackRow extends StatelessWidget {
  const _OfficeFeedbackRow({required this.state, required this.entry});

  final AppState state;
  final OfficeFeedback entry;

  @override
  Widget build(BuildContext context) {
    final rating = entry.rating;
    final details = [
      if (entry.responsivenessRating case final value?) 'Response $value/5',
      if (entry.helpfulnessRating case final value?) 'Helpfulness $value/5',
      if (entry.clarityRating case final value?) 'Clarity $value/5',
    ];
    return SrCard(
      key: ValueKey('office-feedback-${entry.id}'),
      padding: const EdgeInsets.all(SR.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (rating != null)
                SrStatusChip(
                  label: '${entry.overallRating}★ ${rating.label}',
                  tone: rating.tone,
                ),
              const SizedBox(width: SR.space8),
              Expanded(
                child: Text(
                  entry.personName.isEmpty
                      ? entry.personEmail
                      : entry.personName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SrType.body(w: 600),
                ),
              ),
              Text(
                formatStamp(campusWallTime(entry.createdAt)),
                style: SrType.caption(),
              ),
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: SR.space4),
            Text(details.join(' · '), style: SrType.caption()),
          ],
          if (entry.comment.isNotEmpty) ...[
            const SizedBox(height: SR.space8),
            Text(entry.comment, style: SrType.body()),
          ],
        ],
      ),
    );
  }
}
