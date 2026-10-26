import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/support_ticket.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/queue_shell.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import 'support_widgets.dart';

/// Admin support queue: every ticket, filterable by status, with the thread
/// in the side panel.
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  static const _filters = <SupportStatus?>[
    null,
    SupportStatus.open,
    SupportStatus.inProgress,
    SupportStatus.resolved,
    SupportStatus.closed,
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final stacked = MediaQuery.sizeOf(context).width < SR.desktopMin;
    final selected = state.selectedSupportTicket;
    return QueueShell(
      stacked: stacked || selected == null,
      panelOpen: selected != null,
      onClosePanel: () => state.selectSupportTicket(null),
      panel: selected == null
          ? null
          : SupportTicketThread(
              key: ValueKey('support-thread-${selected.id}'),
              state: state,
              ticket: selected,
            ),
      list: _list(context, state),
    );
  }

  Widget _list(BuildContext context, AppState state) {
    final tickets = state.visibleSupportTickets;
    int count(SupportStatus? status) => status == null
        ? state.supportTickets.length
        : state.supportTickets.where((t) => t.status == status).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SrPageHeader(
          eyebrow: 'Help desk',
          description:
              'Questions and problems sent from the app. Replies reach the '
              'requester in the app, by push and by email.',
          actions: [
            SrIconButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Refresh',
              onPressed: state.refreshSupportTickets,
            ),
          ],
        ),
        const SizedBox(height: SR.space16),
        Wrap(
          spacing: SR.space12,
          runSpacing: SR.space12,
          children: [
            SizedBox(
              width: 180,
              child: SrCard(
                child: SrStat(
                  label: 'Needs reply',
                  value: '${state.supportAwaitingCount}',
                  tone: state.supportAwaitingCount > 0
                      ? SrTone.warning
                      : SrTone.neutral,
                ),
              ),
            ),
            SizedBox(
              width: 180,
              child: SrCard(
                child: SrStat(
                  label: 'Open',
                  value: '${count(SupportStatus.open)}',
                ),
              ),
            ),
            SizedBox(
              width: 180,
              child: SrCard(
                child: SrStat(
                  label: 'In progress',
                  value: '${count(SupportStatus.inProgress)}',
                  tone: SrTone.info,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: SR.space16),
        SrTabs(
          scrollable: true,
          items: [
            for (final status in _filters)
              SrTabItem(label: status?.label ?? 'All', count: count(status)),
          ],
          selectedIndex: _filters.indexOf(state.supportStatusFilter),
          onSelect: (index) => state.setSupportStatusFilter(_filters[index]),
        ),
        const SizedBox(height: SR.space16),
        if (state.supportLoading && !state.supportLoaded)
          const SrLoadingState(message: 'Loading tickets…')
        else if (state.supportError case final error?
            when state.supportTickets.isEmpty)
          SrErrorState(
            title: 'Tickets could not be loaded',
            message: error,
            onRetry: state.refreshSupportTickets,
          )
        else if (tickets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: SR.space32),
            child: Text(
              state.supportStatusFilter == null
                  ? 'No support tickets yet.'
                  : 'No ${state.supportStatusFilter!.label.toLowerCase()} '
                        'tickets.',
              textAlign: TextAlign.center,
              style: SrType.bodySm(color: context.srColors.muted),
            ),
          )
        else
          for (final ticket in tickets) ...[
            SupportTicketRow(
              ticket: ticket,
              showRequester: true,
              selected: ticket.id == state.selectedSupportTicketId,
              onTap: () => state.selectSupportTicket(ticket.id),
            ),
            const SizedBox(height: SR.space8),
          ],
      ],
    );
  }
}
