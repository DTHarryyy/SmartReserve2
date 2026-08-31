import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/anomaly.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

import '../../theme/sr_theme.dart';

/// Advisory-only risk summary for a single reservation's renter, scoped to
/// the reviewing administrator's lane and assigned facilities. Never used to
/// automatically reject, cancel, suspend, or ban a renter.
class RiskSummaryCard extends StatelessWidget {
  const RiskSummaryCard({super.key, required this.state, required this.requestId});

  final AppState state;
  final String requestId;

  static String _relative(DateTime value) {
    final difference = DateTime.now().difference(value.toLocal());
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} hours ago';
    return '${difference.inDays} days ago';
  }

  /// Footer status line. A routine background refresh gets a quiet inline
  /// hint rather than blocking the already-readable data above it (see
  /// `backgroundUpdating` in [build]); a stalled evaluation gets its own
  /// banner instead, so this stays unadorned in that case.
  static String _evaluatedLabel(
    RenterRiskSummary summary,
    bool backgroundUpdating,
  ) {
    if (summary.lastEvaluatedAt == null) {
      return backgroundUpdating ? 'Updating · not yet evaluated' : 'Not yet evaluated';
    }
    final relative = _relative(summary.lastEvaluatedAt!);
    return backgroundUpdating ? 'Updating · last evaluated $relative' : 'Evaluated $relative';
  }

  @override
  Widget build(BuildContext context) {
    if (state.usesDemoData) return const SizedBox.shrink();
    final summary = state.riskSummaryFor(requestId);
    final loading = state.riskSummaryLoading(requestId);

    if (summary == null) {
      if (!loading) return const SizedBox.shrink();
      return PanelCard(
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: SR.space12),
            Text('Loading reservation risk…', style: SrType.bodySm()),
          ],
        ),
      );
    }

    final level = summary.riskLevel;
    final topReasons = summary.topReasons.take(3).toList();
    // A stalled evaluation is a genuine backend fault (surfaced by the
    // server via evaluation_stalled, or inferred client-side once bounded
    // polling gives up) — worth a visible fault state with a manual retry.
    // A plain pending/loading evaluation is routine background refresh and
    // should not block the already-readable data underneath it.
    final stalled =
        summary.evaluationStalled || state.riskSummaryPollExhausted(requestId);
    final backgroundUpdating = (loading || summary.evaluationPending) && !stalled;

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Reservation risk', style: SrType.subhead()),
                    const SizedBox(height: SR.space2),
                    Text(summary.portfolioLabel, style: SrType.caption()),
                  ],
                ),
              ),
              const SizedBox(width: SR.space8),
              SrStatusChip(
                label: '${level.label} · ${summary.riskScore}',
                tone: level.tone,
              ),
            ],
          ),
          if (stalled) ...[
            const SizedBox(height: SR.space8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SR.space12,
                vertical: SR.space8,
              ),
              decoration: BoxDecoration(
                color: context.srColors.warningContainer,
                borderRadius: BorderRadius.circular(SR.rSm),
                border: Border.all(color: context.srColors.amberLine),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: context.srColors.warning,
                  ),
                  const SizedBox(width: SR.space8),
                  Expanded(
                    child: Text(
                      'Risk evaluation is taking longer than expected.',
                      style: SrType.caption(color: context.srColors.amberInk),
                    ),
                  ),
                  const SizedBox(width: SR.space8),
                  SrButton(
                    label: 'Refresh',
                    dense: true,
                    fontSize: 11,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    onPressed: () =>
                        state.refreshReservationRiskSummary(requestId),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: SR.space12),
          if (topReasons.isEmpty)
            Text(
              'No active risk signals for this renter in your assigned '
              'portfolio.',
              style: SrType.bodySm(color: context.srColors.ink3),
            )
          else
            for (final reason in topReasons)
              Padding(
                padding: const EdgeInsets.only(bottom: SR.space6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: SR.space8),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: context.srColors.ink3,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${reason['title'] ?? reason['explanation'] ?? ''}',
                        style: SrType.bodySm(),
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: SR.space8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _evaluatedLabel(summary, backgroundUpdating),
                  style: SrType.caption(),
                ),
              ),
              SrButton(
                label: 'View risk details',
                dense: true,
                fontSize: 11,
                onPressed: topReasons.isEmpty
                    ? null
                    : () {
                        final anomalyId = topReasons.first['anomaly_id'];
                        state.goTo(AppView.anomalies);
                        if (anomalyId is String) state.selectAnomaly(anomalyId);
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
