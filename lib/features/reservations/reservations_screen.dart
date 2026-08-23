import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/queue_shell.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import 'conflict_engine.dart';
import 'decision_panel.dart';
import 'reservation_checks.dart';

class ReservationsScreen extends StatelessWidget {
  const ReservationsScreen({super.key});

  static const _tabs = [
    RequestStatus.pending,
    RequestStatus.approved,
    RequestStatus.changesRequested,
    RequestStatus.declined,
    RequestStatus.cancelled,
    RequestStatus.expired,
  ];

  ReservationAssessment _assess(AppState state, ReservationRequest request) =>
      ReservationAssessment(
        request: request,
        facility: state.facilityNamed(request.facility),
        bookings: state.bookings,
        otherRequests: state.requests,
      );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Expanded(child: _queue(context, state))],
    );
  }

  Widget _queue(BuildContext context, AppState state) {
    final stacked = MediaQuery.sizeOf(context).width < SR.desktopMin;
    final rows = state.visibleRequests;
    final selected = state.selectedRequest;

    final assessments = <String, ReservationAssessment>{
      for (final r in rows) r.id: _assess(state, r),
    };
    if (selected != null && !assessments.containsKey(selected.id)) {
      assessments[selected.id] = _assess(state, selected);
    }

    final selectable = [
      for (final id in state.selectedRequestIds)
        if (rows.any((r) => r.id == id)) id,
    ];
    final blocked = selectable
        .where((id) => !assessments[id]!.bulkApprovable)
        .toList();

    return QueueShell(
      stacked: stacked,
      panelOpen: selected != null,
      onClosePanel: () => state.selectRequest(null),
      panel: selected == null
          ? null
          : DecisionPanel(
              state: state,
              assessment: assessments[selected.id]!,

              showBack: false,
              onBack: () => state.selectRequest(null),
            ),
      list: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrTabs(
            scrollable: true,
            items: [
              for (final tab in _tabs)
                SrTabItem(
                  label: tab.label,
                  count: state.requests.where((r) => r.status == tab).length,
                ),
            ],
            selectedIndex: _tabs.indexOf(state.requestTab),
            onSelect: (i) => state.setRequestTab(_tabs[i]),
          ),
          const SizedBox(height: SR.space12),

          if (selectable.isNotEmpty)
            BulkBar(
              label: '${selectable.length} selected',
              actionLabel: 'Approve all conflict-free',
              blockedNote: blocked.isEmpty
                  ? null
                  : '${blocked.length} carry a warning — bulk approve is off '
                        'until they are cleared or deselected.',
              onAction: blocked.isEmpty
                  ? () => state.bulkApproveRequests(selectable)
                  : null,
              onClear: state.clearRequestSelection,
            ),

          if (rows.isEmpty)
            _empty(state)
          else
            for (final request in rows)
              _QueueRow(
                request: request,
                assessment: assessments[request.id]!,
                selected: state.selectedRequestId == request.id,
                checked: state.selectedRequestIds.contains(request.id),
                onOpen: () => state.selectRequest(request.id),
                onToggle: (extend) =>
                    state.toggleRequestSelection(request.id, extend: extend),
              ),

          const SizedBox(height: SR.space12),
          Text(
            'Keyboard: J / K move · A approve · D decline · U undo. Tick a '
            'checkbox, then shift-click another to select the whole range. '
            'Decisions are reversible for a few seconds instead of asking you '
            'to confirm.',
            style: SrType.caption(),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppState state) => ListEmptyState(
    icon: state.requestTab == RequestStatus.pending
        ? Icons.task_alt_rounded
        : Icons.inbox_rounded,
    title: state.requestTab == RequestStatus.pending
        ? 'The queue is clear'
        : 'Nothing here yet',
    body: state.requestTab == RequestStatus.pending
        ? 'Every request has a decision. New ones arrive at the top, '
              'oldest first.'
        : 'Requests appear here once they reach this state.',
  );
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.request,
    required this.assessment,
    required this.selected,
    required this.checked,
    required this.onOpen,
    required this.onToggle,
  });

  final ReservationRequest request;
  final ReservationAssessment assessment;
  final bool selected;
  final bool checked;
  final VoidCallback onOpen;

  final ValueChanged<bool> onToggle;

  String? get _flag {
    if (assessment.hasConflict) {
      return request.isPending ? kCollidesFlag : kOverlapsFlag;
    }
    if (request.overCapacity) return 'Over capacity';
    if (!assessment.withinOperatingHours) return 'Outside operating hours';
    if (!assessment.withinAvailableDays) return 'Not an available day';
    if (request.noShows > 0) return '${request.noShows} prior no-shows';
    return null;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onOpen,
        child: AnimatedContainer(
          duration: SR.stateChange,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: selected ? SR.primaryTint2 : SR.surface,
            borderRadius: BorderRadius.circular(SR.rMd - 1),
            border: Border.all(
              color: selected
                  ? SR.primary
                  : (hovered ? SR.primarySoft : SR.border),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SelectBox(
                  selected: checked,
                  onTap: onToggle,
                  semanticLabel: 'Select ${request.requester}',
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            request.requester,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(13, w: 600, tracking: -.01),
                          ),
                        ),
                        if (request.urgent) ...[
                          const SizedBox(width: SR.space8),
                          const SrStatusChip(
                            label: 'URGENT',
                            tone: SrTone.error,
                            dense: true,
                          ),
                        ],
                        const SizedBox(width: SR.space8),
                        Text(
                          request.submitted,
                          style: mono(10.5, color: SR.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      request.org,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11.5, color: SR.ink4),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      request.facility,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11.5, color: SR.ink2),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          request.whenLabel,
                          style: mono(11, w: 500, color: SR.ink3),
                        ),
                        Text(
                          '${request.heads} people',
                          style: mono(10.5, color: SR.muted),
                        ),
                        if (request.amenities.isNotEmpty)
                          Tooltip(
                            message: request.amenities.join(', '),
                            child: Text(
                              '+${request.amenities.length} amenities',
                              style: mono(10.5, color: SR.muted),
                            ),
                          ),
                        SrStatusChip(
                          label: request.status.label,
                          tone: request.status.tone,
                          dense: true,
                        ),
                        if (_flag case final flag?)
                          Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                size: SR.iconSm,
                                color: SR.amber,
                              ),
                              const SizedBox(width: SR.space4),
                              Expanded(
                                child: Text(
                                  flag,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: SrType.caption(
                                    w: 500,
                                    color: SR.amber,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
