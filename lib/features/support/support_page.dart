import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../model/support_ticket.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'support_widgets.dart';

/// The renter's help page: their tickets, a button to open a new one, and
/// the conversation for whichever ticket they open.
class SupportPage extends StatefulWidget {
  const SupportPage({super.key, this.initialTicketId});

  /// Opens straight into this ticket (from a notification).
  final String? initialTicketId;

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  String? _openTicketId;

  @override
  void initState() {
    super.initState();
    _openTicketId = widget.initialTicketId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(AppScope.read(context).refreshSupportTickets());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final open = state.supportTicketById(_openTicketId);
    return PopScope(
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _openTicketId = null);
      },
      child: Scaffold(
        backgroundColor: context.srColors.bg,
        appBar: AppBar(
          title: Text(open == null ? 'Help & support' : 'Ticket'),
          leading: open == null
              ? null
              : IconButton(
                  tooltip: 'All tickets',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() => _openTicketId = null),
                ),
        ),
        body: SrScrollView(
          padding: SR.pageInsets(width, bottom: SR.space32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: open != null
                  ? SupportTicketThread(
                      key: ValueKey('support-thread-${open.id}'),
                      state: state,
                      ticket: open,
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SrCard(
                          level: SrCardLevel.tinted,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Need a hand?', style: SrType.subhead()),
                              const SizedBox(height: SR.space4),
                              Text(
                                'Report a problem with your account, a '
                                'reservation, a payment, or the app. The '
                                'SmartReserve team replies here and by '
                                'email.',
                                style: SrType.bodySm(),
                              ),
                              const SizedBox(height: SR.space12),
                              SrButton(
                                key: const Key('support-new-ticket'),
                                label: 'New ticket',
                                kind: SrButtonKind.primary,
                                icon: const Icon(Icons.add_rounded, size: 18),
                                onPressed: () async {
                                  final ticket =
                                      await showNewSupportTicketDialog(
                                        context,
                                        state: state,
                                      );
                                  if (ticket != null && mounted) {
                                    setState(() => _openTicketId = ticket.id);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: SR.space20),
                        Text('Your tickets', style: SrType.overline()),
                        const SizedBox(height: SR.space8),
                        if (state.supportLoading && !state.supportLoaded)
                          const SrLoadingState(message: 'Loading tickets…')
                        else if (state.supportTickets.isEmpty)
                          Text(
                            state.supportError ??
                                'You have not contacted support yet.',
                            style: SrType.bodySm(color: context.srColors.muted),
                          )
                        else
                          for (final SupportTicket ticket
                              in state.supportTickets) ...[
                            SupportTicketRow(
                              ticket: ticket,
                              onTap: () =>
                                  setState(() => _openTicketId = ticket.id),
                            ),
                            const SizedBox(height: SR.space8),
                          ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
