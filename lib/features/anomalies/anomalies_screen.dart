import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/anomaly.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/queue_shell.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import 'anomaly_detail.dart';

import '../../theme/sr_theme.dart';

const _sharedRuleLabels = <String, String>{
  'repeated_no_show': 'Repeated no-show',
  'consecutive_no_show_cluster': 'No-show cluster',
  'excessive_reservation_creation': 'Excessive creation',
  'facility_slot_hoarding': 'Facility slot hoarding',
  'repeated_late_cancellation': 'Repeated late cancellation',
  'reserve_cancel_reserve_cycle': 'Reserve/cancel/reserve cycle',
  'overlapping_reservations': 'Overlapping reservations',
  'abnormal_duration': 'Abnormal duration',
};

const _paymentOnlyRuleLabels = <String, String>{
  'missed_down_payment': 'Missed down payment',
  'payment_deadline_expiration': 'Payment deadline expiration',
  'full_payment_deadline_failure': 'Full-payment deadline failure',
  'payment_slot_blocking': 'Payment slot blocking',
};

/// Shared Anomaly Center for both administrator lanes. The backend already
/// scopes rows to the caller's lane and assigned facilities, so this screen
/// only changes its copy and available filters between Internal and
/// External Admin — never the query shape.
class AnomaliesScreen extends StatelessWidget {
  const AnomaliesScreen({super.key});

  static const _columns = [
    ColSpec('RENTER', flex: 2),
    ColSpec('RISK', width: 70),
    ColSpec('ANOMALY', flex: 2),
    ColSpec('FACILITY', flex: 2, hide: ColumnHide.small),
    ColSpec('EVIDENCE', flex: 2, hide: ColumnHide.medium),
    ColSpec('DETECTED', width: 84, hide: ColumnHide.medium),
    ColSpec('STATUS', width: 104),
    ColSpec('ACTIONS', width: 108, alignRight: true),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final stacked = MediaQuery.sizeOf(context).width < SR.desktopMin;

    return QueueShell(
      stacked: stacked,
      panelOpen: state.selectedAnomalyId != null,
      onClosePanel: () => state.selectAnomaly(null),
      panel: state.selectedAnomalyId == null
          ? null
          : AnomalyDetailPanel(
              state: state,
              anomalyId: state.selectedAnomalyId!,
            ),
      list: _list(context, state),
    );
  }

  Widget _list(BuildContext context, AppState state) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SrPageHeader(
        eyebrow: state.isExternalAdmin
            ? 'External renter reservation risk'
            : 'Verified-user reservation risk',
        title: 'Anomaly Center',
        description:
            'Deterministic, explainable risk signals for your assigned '
            'facilities. Risk is advisory — it never auto-rejects or bans '
            'a renter.',
        actions: [
          SrIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Refresh',
            onPressed: () => state.refreshAnomalyCenter(),
          ),
        ],
      ),
      const SizedBox(height: SR.space16),
      _metrics(context, state),
      const SizedBox(height: SR.space16),
      _filters(context, state),
      const SizedBox(height: SR.space16),
      _rows(context, state),
    ],
  );

  Widget _metrics(BuildContext context, AppState state) {
    final m = state.anomalyMetrics;
    final cards = <(String, String, SrTone)>[
      ('Needs review', '${m.needsReviewCount}', SrTone.warning),
      ('Open', '${m.openCount}', SrTone.neutral),
      ('Acknowledged', '${m.acknowledgedCount}', SrTone.info),
      ('Critical', '${m.criticalCount}', SrTone.error),
      ('High', '${m.highCount}', SrTone.warning),
      if (state.isExternalAdmin)
        ('Payment-related', '${m.paymentCount}', SrTone.info),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 860
            ? cards.length
            : constraints.maxWidth >= 560
            ? 3
            : 2;
        final width =
            (constraints.maxWidth - (columns - 1) * SR.space12) / columns;
        return Wrap(
          spacing: SR.space12,
          runSpacing: SR.space12,
          children: [
            for (final (label, value, tone) in cards)
              SizedBox(
                width: width,
                child: SrCard(
                  child: SrStat(label: label, value: value, tone: tone),
                ),
              ),
          ],
        );
      },
    );
  }

  int _statusTabIndex(AnomalyFilters filters) {
    if (filters.statuses.length == 1 && filters.statuses.first == 'resolved') {
      return 1;
    }
    if (filters.statuses.length == 1 &&
        filters.statuses.first == 'false_positive') {
      return 2;
    }
    return 0;
  }

  List<String> _statusesFor(int index) => switch (index) {
    1 => const ['resolved'],
    2 => const ['false_positive'],
    _ => const ['open', 'acknowledged'],
  };

  Widget _filters(BuildContext context, AppState state) {
    final filters = state.anomalyFilters;
    final ruleLabels = {
      ..._sharedRuleLabels,
      if (state.isExternalAdmin) ..._paymentOnlyRuleLabels,
    };
    final selectedRule = filters.rules.isEmpty ? null : filters.rules.first;

    return Wrap(
      spacing: SR.space12,
      runSpacing: SR.space12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SrTabs(
          items: const [
            SrTabItem(label: 'Active'),
            SrTabItem(label: 'Resolved'),
            SrTabItem(label: 'False positive'),
          ],
          selectedIndex: _statusTabIndex(filters),
          onSelect: (index) => state.setAnomalyFilters(
            filters.copyWith(statuses: _statusesFor(index)),
          ),
        ),
        SizedBox(
          width: 220,
          child: SrSelect<String>(
            value: selectedRule,
            items: ruleLabels.keys.toList(),
            placeholder: 'All rules',
            semanticLabel: 'Filter by rule',
            labelOf: (key) => ruleLabels[key] ?? key,
            onChanged: (key) => state.setAnomalyFilters(
              filters.copyWith(rules: key == null ? const [] : [key]),
            ),
          ),
        ),
        SrToggle(
          value: filters.includeObserve,
          label: 'Calibration signals',
          onChanged: (value) => state.setAnomalyFilters(
            filters.copyWith(includeObserve: value),
          ),
        ),
      ],
    );
  }

  Widget _rows(BuildContext context, AppState state) {
    if (state.anomalyError case final error?) {
      return SrErrorState(
        title: 'The Anomaly Center could not load',
        message: error,
        onRetry: () => state.refreshAnomalyCenter(),
      );
    }
    if (state.anomalyLoading && state.anomalyRows.isEmpty) {
      return RecordTable(
        columns: _columns,
        children: [
          for (var i = 0; i < 4; i++)
            SkeletonRow(columns: _columns, leadWidth: .5),
        ],
      );
    }
    if (state.anomalyRows.isEmpty) {
      return _emptyState(state);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RecordTable(
          columns: _columns,
          children: [
            for (final anomaly in state.anomalyRows)
              RecordRow(
                columns: _columns,
                cells: _cells(context, state, anomaly),
                onTap: () => state.selectAnomaly(anomaly.id),
              ),
          ],
        ),
        if (state.anomalyHasMore) ...[
          const SizedBox(height: SR.space12),
          Center(
            child: SrButton(
              label: state.anomalyLoadingMore ? 'Loading…' : 'Load more',
              onPressed: state.anomalyLoadingMore
                  ? null
                  : () => state.loadMoreAnomalies(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _emptyState(AppState state) {
    if (state.anomalyFilters.includeObserve) {
      return const ListEmptyState(
        icon: Icons.science_outlined,
        title: 'No calibration signals',
        body:
            'Observe-mode rules have not produced any rows in this window. '
            'These never affect risk until a rule is activated.',
      );
    }
    return ListEmptyState(
      icon: Icons.shield_moon_outlined,
      title: state.isExternalAdmin
          ? 'No active external renter anomalies'
          : 'No active internal anomalies',
      body:
          'New detections appear here within about a minute of the '
          'triggering reservation, occurrence, or payment event.',
    );
  }

  static String _shortDate(DateTime value) =>
      '${value.day}/${value.month}/${value.year}';

  static String _evidenceSummaryText(Map<String, dynamic> summary) {
    if (summary.isEmpty) return '—';
    final parts = <String>[
      for (final entry in summary.entries.take(3))
        '${entry.key.replaceAll('_', ' ')}: ${entry.value}',
    ];
    return parts.join(' · ');
  }

  static SrTone _statusTone(AnomalyStatus status) => switch (status) {
    AnomalyStatus.open => SrTone.warning,
    AnomalyStatus.acknowledged => SrTone.info,
    AnomalyStatus.resolved => SrTone.success,
    AnomalyStatus.falsePositive => SrTone.neutral,
  };

  List<Widget> _cells(
    BuildContext context,
    AppState state,
    ReservationAnomaly anomaly,
  ) => [
    Text(
      anomaly.renterName.isEmpty ? 'Renter' : anomaly.renterName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: sans(12.5, w: 600),
    ),
    SrStatusChip(
      label: '${anomaly.localRiskScore}',
      tone: anomaly.localRiskLevel.tone,
      dense: true,
    ),
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          anomaly.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sans(12, w: 600),
        ),
        const SizedBox(height: 3),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            SrStatusChip(
              label: anomaly.severity.label,
              tone: anomaly.severity.tone,
              dense: true,
            ),
            if (anomaly.isObserve)
              SrStatusChip(
                label: 'Not affecting risk',
                tone: SrTone.neutral,
                dense: true,
              ),
          ],
        ),
      ],
    ),
    Text(
      anomaly.facilityName.isEmpty ? '—' : anomaly.facilityName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: sans(12, color: context.srColors.ink3),
    ),
    Text(
      _evidenceSummaryText(anomaly.evidenceSummary),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: SrType.caption(),
    ),
    Text(_shortDate(anomaly.lastDetectedAt), style: mono(11)),
    SrStatusChip(
      label: anomaly.status.label,
      tone: _statusTone(anomaly.status),
      dense: true,
    ),
    anomaly.status == AnomalyStatus.open
        ? SrButton(
            label: 'Acknowledge',
            dense: true,
            fontSize: 10.5,
            onPressed: () => state.transitionAnomaly(
              anomalyId: anomaly.id,
              action: 'acknowledge',
            ),
          )
        : const SizedBox.shrink(),
  ];
}
