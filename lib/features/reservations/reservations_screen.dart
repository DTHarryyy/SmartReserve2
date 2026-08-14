import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/queue_shell.dart';
import '../../widgets/sr_controls.dart';
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

    final selectable = [
      for (final id in state.selectedRequestIds)
        if (rows.any((r) => r.id == id)) id,
    ];
    final blocked = selectable.where((id) {
      final r = rows.firstWhere((r) => r.id == id);
      return !_assess(state, r).bulkApprovable;
    }).toList();

    return QueueShell(
      stacked: stacked,
      panelOpen: selected != null,
      onClosePanel: () => state.selectRequest(null),
      panel: selected == null
          ? null
          : DecisionPanel(
              state: state,
              assessment: _assess(state, selected),

              showBack: false,
              onBack: () => state.selectRequest(null),
            ),
      list: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              spacing: 6,
              children: [
                for (final tab in _tabs)
                  QueueTab(
                    label: tab.label,
                    count: state.requests.where((r) => r.status == tab).length,
                    selected: state.requestTab == tab,
                    onTap: () => state.setRequestTab(tab),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

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
                assessment: _assess(state, request),
                selected: state.selectedRequestId == request.id,
                checked: state.selectedRequestIds.contains(request.id),
                onOpen: () => state.selectRequest(request.id),
                onToggle: (extend) =>
                    state.toggleRequestSelection(request.id, extend: extend),
              ),

          const SizedBox(height: 12),
          Text(
            'Keyboard: J / K move · A approve · D decline · U undo. Tick a '
            'checkbox, then shift-click another to select the whole range. '
            'Decisions are reversible for a few seconds instead of asking you '
            'to confirm.',
            style: sans(11, height: 1.6, color: SR.muted),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppState state) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 52),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: SR.greenTint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.check_rounded, size: 20, color: SR.greenDark),
        ),
        const SizedBox(height: 14),
        Text(
          state.requestTab == RequestStatus.pending
              ? 'The queue is clear'
              : 'Nothing here yet',
          style: sans(14, w: 600),
        ),
        const SizedBox(height: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            state.requestTab == RequestStatus.pending
                ? 'Every request has a decision. New ones arrive at the top, '
                      'oldest first.'
                : 'Requests appear here once they reach this state.',
            textAlign: TextAlign.center,
            style: sans(12, height: 1.6, color: SR.ink4),
          ),
        ),
      ],
    ),
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
    if (assessment.hasConflict) return 'Collides with a booking';
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
            color: selected ? SR.blueTint2 : SR.surface,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected ? SR.blue : (hovered ? SR.blueSoft : SR.border),
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
                        Flexible(
                          child: Text(
                            request.requester,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(13, w: 600, tracking: -.01),
                          ),
                        ),
                        if (request.urgent) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: SR.redTint,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'URGENT',
                              style: mono(
                                9,
                                w: 600,
                                tracking: .04,
                                color: const Color(0xFF912018),
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
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
                        SrPill(
                          label: request.status.label,
                          background: request.status.background,
                          foreground: request.status.foreground,
                          fontSize: 10,
                        ),
                        if (_flag case final flag?)
                          Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                size: 12,
                                color: SR.amber,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  flag,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: sans(10.5, w: 500, color: SR.amber),
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
