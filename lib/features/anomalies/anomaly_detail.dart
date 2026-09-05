import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/anomaly.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

import '../../theme/sr_theme.dart';

const _falsePositiveReasons = <String, String>{
  'legitimate_recurring_event': 'Legitimate recurring event',
  'officially_approved_repeated_booking':
      'Officially approved repeated booking',
  'emergency_cancellation': 'Emergency cancellation',
  'incorrect_attendance_record': 'Incorrect attendance record',
  'duplicate_detection': 'Duplicate detection',
  'system_error': 'System error',
  'other': 'Other',
};

enum _Prompt { none, resolve, falsePositive }

/// Detail panel for a single anomaly, shown inside the Anomaly Center's
/// master/detail layout. Every action here is advisory: it never rejects,
/// cancels, suspends, or bans a renter — it only records a human decision.
class AnomalyDetailPanel extends StatefulWidget {
  const AnomalyDetailPanel({
    super.key,
    required this.state,
    required this.anomalyId,
  });

  final AppState state;
  final String anomalyId;

  @override
  State<AnomalyDetailPanel> createState() => _AnomalyDetailPanelState();
}

class _AnomalyDetailPanelState extends State<AnomalyDetailPanel> {
  _Prompt _prompt = _Prompt.none;
  String _falsePositiveReason = _falsePositiveReasons.keys.first;
  final _noteController = TextEditingController();
  bool _busy = false;
  bool _noteAttempted = false;

  @override
  void didUpdateWidget(AnomalyDetailPanel old) {
    super.didUpdateWidget(old);
    if (old.anomalyId != widget.anomalyId) {
      _prompt = _Prompt.none;
      _falsePositiveReason = _falsePositiveReasons.keys.first;
      _noteController.clear();
      _noteAttempted = false;
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  static String _relative(DateTime value) {
    final difference = DateTime.now().difference(value.toLocal());
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} hours ago';
    return '${difference.inDays} days ago';
  }

  Future<void> _transition(
    String action, {
    String? reasonCode,
    String? note,
  }) async {
    setState(() => _busy = true);
    final ok = await widget.state.transitionAnomaly(
      anomalyId: widget.anomalyId,
      action: action,
      reasonCode: reasonCode,
      note: note,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _prompt = _Prompt.none;
        _noteController.clear();
        _noteAttempted = false;
      }
    });
  }

  void _submitFalsePositive() {
    final note = _noteController.text.trim();
    if (_falsePositiveReason == 'other' && note.isEmpty) {
      setState(() => _noteAttempted = true);
      return;
    }
    unawaited(
      _transition(
        'false_positive',
        reasonCode: _falsePositiveReason,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state.anomalyDetailLoading && state.selectedAnomalyDetail == null) {
      return const PanelCard(
        child: SrLoadingState(message: 'Loading anomaly…'),
      );
    }
    if (state.anomalyDetailError case final error?) {
      return PanelCard(
        child: SrErrorState(
          title: 'This anomaly could not load',
          message: error,
          onRetry: () => state.loadAnomalyDetail(widget.anomalyId),
        ),
      );
    }
    final detail = state.selectedAnomalyDetail;
    if (detail == null || detail.anomaly.id != widget.anomalyId) {
      return const PanelCard(child: SrLoadingState());
    }
    final anomaly = detail.anomaly;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelCard(child: _overview(context, anomaly)),
        PanelCard(child: _evidence(context, detail)),
        if (anomaly.status == AnomalyStatus.open ||
            anomaly.status == AnomalyStatus.acknowledged)
          PanelCard(child: _actions(context, anomaly)),
      ],
    );
  }

  Widget _overview(BuildContext context, ReservationAnomaly anomaly) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(anomaly.title, style: SrType.subhead()),
                const SizedBox(height: SR.space2),
                Text(
                  '${anomaly.facilityName.isEmpty ? 'Facility' : anomaly.facilityName}'
                  '${anomaly.facilityBuilding.isEmpty ? '' : ' · ${anomaly.facilityBuilding}'}',
                  style: SrType.caption(),
                ),
              ],
            ),
          ),
          const SizedBox(width: SR.space8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SrStatusChip(
                label: anomaly.severity.label,
                tone: anomaly.severity.tone,
              ),
              const SizedBox(height: SR.space6),
              SrStatusChip(
                label: anomaly.status.label,
                tone: switch (anomaly.status) {
                  AnomalyStatus.acknowledged => SrTone.info,
                  AnomalyStatus.resolved => SrTone.success,
                  AnomalyStatus.falsePositive => SrTone.neutral,
                  AnomalyStatus.open => SrTone.warning,
                },
                dense: true,
              ),
            ],
          ),
        ],
      ),
      if (anomaly.isObserve) ...[
        const SizedBox(height: SR.space8),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SR.space12,
            vertical: SR.space8,
          ),
          decoration: BoxDecoration(
            color: context.srColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(SR.rSm),
            border: Border.all(color: context.srColors.hairline),
          ),
          child: Text(
            'Calibration signal · 0 points · not affecting risk',
            style: SrType.caption(),
          ),
        ),
      ],
      const SizedBox(height: SR.space12),
      Text('Why was this detected?', style: SrType.label()),
      const SizedBox(height: SR.space4),
      Text(
        anomaly.explanation,
        style: SrType.body(color: context.srColors.ink3),
      ),
      const SizedBox(height: SR.space12),
      Wrap(
        spacing: SR.space8,
        runSpacing: SR.space8,
        children: [
          SrFactChip(
            label: 'Points',
            value: anomaly.isObserve
                ? '0 of ${anomaly.baseRiskPoints} (observe)'
                : '${anomaly.effectiveRiskPoints} of ${anomaly.baseRiskPoints}',
          ),
          SrFactChip(
            label: 'Window',
            value:
                '${_shortDate(anomaly.windowStartedAt)} – '
                '${_shortDate(anomaly.windowEndedAt)}',
          ),
          SrFactChip(
            label: 'Detection mode',
            value: anomaly.isObserve ? 'Observe' : 'Active',
          ),
          SrFactChip(
            label: 'Last evaluated',
            value: _relative(anomaly.lastEvaluatedAt),
          ),
        ],
      ),
    ],
  );

  Widget _evidence(BuildContext context, AnomalyDetail detail) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Evidence', style: SrType.subhead()),
      const SizedBox(height: SR.space2),
      Text(
        'Every record behind this detection, most recent first.',
        style: SrType.caption(),
      ),
      const SizedBox(height: SR.space12),
      if (detail.evidence.isEmpty)
        Text('No evidence in your assigned scope.', style: SrType.bodySm())
      else
        for (final item in detail.evidence)
          Padding(
            padding: const EdgeInsets.only(bottom: SR.space8),
            child: Hoverable(
              builder: (context, hovered) => GestureDetector(
                onTap: () =>
                    widget.state.openReservationFromAnomaly(item.requestId),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SR.space12,
                    vertical: SR.space8,
                  ),
                  decoration: BoxDecoration(
                    color: hovered
                        ? context.srColors.surfaceSubtle
                        : context.srColors.surface,
                    borderRadius: BorderRadius.circular(SR.rSm),
                    border: Border.all(color: context.srColors.hairline),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.evidenceRole.replaceAll('_', ' '),
                              style: SrType.bodySm(w: 600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${item.requestTitle.isEmpty ? 'Reservation' : item.requestTitle} · '
                              '${_relative(item.observedAt)}',
                              style: SrType.caption(),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: SR.iconMd,
                        color: context.srColors.mutedLight,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      if (detail.restrictedEvidenceCount > 0) ...[
        const SizedBox(height: SR.space4),
        Text(
          '${detail.restrictedEvidenceCount} additional evidence record'
          '${detail.restrictedEvidenceCount == 1 ? '' : 's'} from a facility '
          'outside your assignment — shown as a count only.',
          style: SrType.caption(),
        ),
      ],
    ],
  );

  Widget _actions(BuildContext context, ReservationAnomaly anomaly) {
    if (_prompt == _Prompt.falsePositive) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrLabel('False-positive reason', required: true),
          SrSelect<String>(
            value: _falsePositiveReason,
            items: _falsePositiveReasons.keys.toList(),
            labelOf: (key) => _falsePositiveReasons[key]!,
            onChanged: (value) => setState(
              () => _falsePositiveReason =
                  value ?? _falsePositiveReasons.keys.first,
            ),
          ),
          const SizedBox(height: SR.space8),
          SrTextField(
            controller: _noteController,
            placeholder: _falsePositiveReason == 'other'
                ? 'Required — explain why this was a false positive.'
                : 'Optional note.',
            minLines: 2,
            maxLines: 4,
            hasError: _noteAttempted && _noteController.text.trim().isEmpty,
            onChanged: (_) => setState(() {}),
          ),
          if (_noteAttempted && _noteController.text.trim().isEmpty)
            const SrErrorText('A note is required for "Other".'),
          const SizedBox(height: SR.space8),
          Row(
            children: [
              SrButton(
                label: _busy ? 'Saving…' : 'Submit',
                kind: SrButtonKind.primary,
                onPressed: _busy ? null : _submitFalsePositive,
              ),
              const SizedBox(width: SR.space8),
              SrButton(
                label: 'Cancel',
                onPressed: _busy
                    ? null
                    : () => setState(() => _prompt = _Prompt.none),
              ),
            ],
          ),
        ],
      );
    }
    if (_prompt == _Prompt.resolve) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Resolve this anomaly', style: SrType.label()),
          const SizedBox(height: SR.space4),
          Text(
            'The condition no longer applies. This clears its risk points.',
            style: SrType.caption(),
          ),
          const SizedBox(height: SR.space8),
          SrTextField(
            controller: _noteController,
            placeholder: 'Optional note.',
            minLines: 2,
            maxLines: 4,
          ),
          const SizedBox(height: SR.space8),
          Row(
            children: [
              SrButton(
                label: _busy ? 'Saving…' : 'Confirm resolve',
                kind: SrButtonKind.success,
                onPressed: _busy
                    ? null
                    : () {
                        final note = _noteController.text.trim();
                        unawaited(
                          _transition(
                            'resolve',
                            note: note.isEmpty ? null : note,
                          ),
                        );
                      },
              ),
              const SizedBox(width: SR.space8),
              SrButton(
                label: 'Cancel',
                onPressed: _busy
                    ? null
                    : () => setState(() => _prompt = _Prompt.none),
              ),
            ],
          ),
        ],
      );
    }

    return Wrap(
      spacing: SR.space8,
      runSpacing: SR.space8,
      children: [
        if (anomaly.status == AnomalyStatus.open)
          SrButton(
            label: _busy ? 'Saving…' : 'Acknowledge',
            kind: SrButtonKind.primary,
            onPressed: _busy
                ? null
                : () => unawaited(_transition('acknowledge')),
          ),
        SrButton(
          label: 'Resolve',
          kind: SrButtonKind.success,
          onPressed: _busy
              ? null
              : () => setState(() => _prompt = _Prompt.resolve),
        ),
        SrButton(
          label: 'False positive',
          onPressed: _busy
              ? null
              : () => setState(() => _prompt = _Prompt.falsePositive),
        ),
      ],
    );
  }

  static String _shortDate(DateTime value) =>
      '${value.day}/${value.month}/${value.year}';
}
