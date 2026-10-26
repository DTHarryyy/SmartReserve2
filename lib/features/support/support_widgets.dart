import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/notice.dart';
import '../../model/support_ticket.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

String supportStamp(DateTime value) => formatStamp(campusWallTime(value));

class SupportStatusChip extends StatelessWidget {
  const SupportStatusChip({super.key, required this.status});

  final SupportStatus status;

  @override
  Widget build(BuildContext context) =>
      SrStatusChip(label: status.label, tone: status.tone, dot: true);
}

/// One row in a ticket list (admin queue or the renter's own tickets).
class SupportTicketRow extends StatelessWidget {
  const SupportTicketRow({
    super.key,
    required this.ticket,
    required this.onTap,
    this.showRequester = false,
    this.selected = false,
  });

  final SupportTicket ticket;
  final VoidCallback onTap;
  final bool showRequester;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Semantics(
      button: true,
      selected: selected,
      label: ticket.subject,
      child: SrCard(
        key: ValueKey('support-ticket-${ticket.id}'),
        level: selected ? SrCardLevel.tinted : SrCardLevel.flat,
        onTap: onTap,
        padding: const EdgeInsets.all(SR.space12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ticket.category.icon, size: SR.iconMd, color: c.ink3),
            const SizedBox(width: SR.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ticket.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SrType.body(w: 600),
                  ),
                  const SizedBox(height: SR.space2),
                  Text(
                    [
                      if (showRequester) ticket.requesterName,
                      ticket.category.label,
                      supportStamp(ticket.lastActivityAt),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SrType.caption(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: SR.space8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SupportStatusChip(status: ticket.status),
                if (showRequester && ticket.awaitingAdmin) ...[
                  const SizedBox(height: SR.space4),
                  Text(
                    'Needs reply',
                    style: SrType.caption(w: 600, color: SrTone.warning.ink),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The full conversation for a ticket, with a reply box and the status
/// actions the viewer may take.
class SupportTicketThread extends StatefulWidget {
  const SupportTicketThread({
    super.key,
    required this.state,
    required this.ticket,
  });

  final AppState state;
  final SupportTicket ticket;

  @override
  State<SupportTicketThread> createState() => _SupportTicketThreadState();
}

class _SupportTicketThreadState extends State<SupportTicketThread> {
  final _reply = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    final ok = await widget.state.replySupportTicket(
      widget.ticket.id,
      _reply.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _reply.clear();
  }

  Future<void> _setStatus(SupportStatus status) async {
    setState(() => _busy = true);
    await widget.state.setSupportTicketStatus(widget.ticket.id, status);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openAttachment(String path) async {
    final url = await widget.state.supportAttachmentUrl(path);
    if (url == null) {
      widget.state.showToast(
        const ToastMessage(
          'The screenshot could not be opened.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  List<Widget> _statusActions(SupportTicket ticket) {
    final admin = widget.state.isAdmin;
    final actions = <(String, SupportStatus, SrButtonKind)>[
      if (admin && ticket.status == SupportStatus.open)
        ('Start working', SupportStatus.inProgress, SrButtonKind.secondary),
      if (admin && ticket.status.isActive)
        ('Mark resolved', SupportStatus.resolved, SrButtonKind.primary),
      if (ticket.status == SupportStatus.resolved)
        ('Reopen', SupportStatus.open, SrButtonKind.secondary),
      if (ticket.status != SupportStatus.closed)
        ('Close ticket', SupportStatus.closed, SrButtonKind.ghost),
      if (admin && ticket.status == SupportStatus.closed)
        ('Reopen', SupportStatus.open, SrButtonKind.secondary),
    ];
    return [
      for (final (label, status, kind) in actions)
        SrButton(
          key: ValueKey('support-status-${status.raw}'),
          label: label,
          kind: kind,
          dense: true,
          onPressed: _busy ? null : () => _setStatus(status),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ticket = widget.ticket;
    final c = context.srColors;
    final closed = ticket.status == SupportStatus.closed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(ticket.subject, style: SrType.heading())),
            const SizedBox(width: SR.space8),
            SupportStatusChip(status: ticket.status),
          ],
        ),
        const SizedBox(height: SR.space4),
        Text(
          '${ticket.category.label} · opened '
          '${supportStamp(ticket.createdAt)}'
          '${widget.state.isAdmin ? ' · ${ticket.requesterName} '
                    '(${ticket.requesterEmail})' : ''}',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space16),
        _Bubble(
          author: widget.state.isAdmin ? ticket.requesterName : 'You',
          fromAdmin: false,
          message: ticket.message,
          at: ticket.createdAt,
        ),
        if (ticket.attachmentPath case final path?)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('support-attachment'),
              onPressed: () => _openAttachment(path),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('View screenshot'),
            ),
          ),
        for (final reply in ticket.replies)
          _Bubble(
            author: reply.fromAdmin
                ? (widget.state.isAdmin
                      ? reply.authorName
                      : 'SmartReserve support')
                : (widget.state.isAdmin ? reply.authorName : 'You'),
            fromAdmin: reply.fromAdmin,
            message: reply.message,
            at: reply.createdAt,
          ),
        const SizedBox(height: SR.space12),
        if (closed)
          Text(
            'This ticket is closed. Open a new ticket if you still need help.',
            style: SrType.bodySm(color: c.muted),
          )
        else ...[
          TextField(
            key: const Key('support-reply-field'),
            controller: _reply,
            minLines: 2,
            maxLines: 6,
            maxLength: SupportLimits.replyMax,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: widget.state.isAdmin
                  ? 'Reply to ${ticket.requesterName}'
                  : 'Add a reply',
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: SrButton(
              key: const Key('support-reply-send'),
              label: _busy ? 'Sending…' : 'Send reply',
              kind: SrButtonKind.primary,
              icon: const Icon(Icons.send_rounded, size: 16),
              onPressed: _busy ? null : _send,
            ),
          ),
        ],
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: _statusActions(ticket),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.author,
    required this.fromAdmin,
    required this.message,
    required this.at,
  });

  final String author;
  final bool fromAdmin;
  final String message;
  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: SR.space8),
      child: Container(
        padding: const EdgeInsets.all(SR.space12),
        decoration: BoxDecoration(
          color: fromAdmin ? c.primaryTint2 : c.surfaceSubtle,
          borderRadius: BorderRadius.circular(SR.rMd),
          border: Border.all(color: fromAdmin ? c.primaryLine : c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (fromAdmin) ...[
                  Icon(Icons.support_agent_rounded, size: 14, color: c.brand),
                  const SizedBox(width: SR.space4),
                ],
                Expanded(
                  child: Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SrType.caption(w: 600, color: c.ink),
                  ),
                ),
                Text(supportStamp(at), style: SrType.caption()),
              ],
            ),
            const SizedBox(height: SR.space4),
            SelectableText(message, style: SrType.body()),
          ],
        ),
      ),
    );
  }
}

/// Collects a new ticket. Resolves to the created ticket, or null.
Future<SupportTicket?> showNewSupportTicketDialog(
  BuildContext context, {
  required AppState state,
  SupportCategory initialCategory = SupportCategory.other,
}) => showDialog<SupportTicket>(
  context: context,
  builder: (_) =>
      _NewTicketDialog(state: state, initialCategory: initialCategory),
);

class _NewTicketDialog extends StatefulWidget {
  const _NewTicketDialog({required this.state, required this.initialCategory});

  final AppState state;
  final SupportCategory initialCategory;

  @override
  State<_NewTicketDialog> createState() => _NewTicketDialogState();
}

class _NewTicketDialogState extends State<_NewTicketDialog> {
  late SupportCategory _category = widget.initialCategory;
  final _subject = TextEditingController();
  final _message = TextEditingController();
  ReservationUpload? _attachment;
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    if (bytes.isEmpty ||
        bytes.lengthInBytes > SupportLimits.attachmentMaxBytes) {
      setState(() => _error = 'Screenshots must be a PNG or JPEG up to 5 MB.');
      return;
    }
    setState(() {
      _error = null;
      _attachment = ReservationUpload(
        name: picked.name,
        mimeType: picked.name.toLowerCase().endsWith('.png')
            ? 'image/png'
            : 'image/jpeg',
        bytes: bytes,
      );
    });
  }

  Future<void> _submit() async {
    final draft = SupportTicketDraft(
      category: _category,
      subject: _subject.text,
      message: _message.text,
    );
    final invalid = draft.error;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final ticket = await widget.state.createSupportTicket(
      draft,
      attachment: _attachment,
    );
    if (!mounted) return;
    if (ticket != null) {
      Navigator.pop(context, ticket);
    } else {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Contact technical support'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Tell us what went wrong. Support replies here and by email.',
              style: SrType.bodySm(color: context.srColors.muted),
            ),
            const SizedBox(height: SR.space12),
            DropdownButtonFormField<SupportCategory>(
              key: const Key('support-category'),
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Topic'),
              items: [
                for (final category in SupportCategory.values)
                  DropdownMenuItem(
                    value: category,
                    child: Text(category.label),
                  ),
              ],
              onChanged: _sending
                  ? null
                  : (value) => setState(() => _category = value ?? _category),
            ),
            const SizedBox(height: SR.space8),
            TextField(
              key: const Key('support-subject'),
              controller: _subject,
              maxLength: SupportLimits.subjectMax,
              enabled: !_sending,
              decoration: const InputDecoration(labelText: 'Subject'),
            ),
            TextField(
              key: const Key('support-message'),
              controller: _message,
              minLines: 4,
              maxLines: 8,
              maxLength: SupportLimits.messageMax,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'What happened?',
                helperText:
                    'Include the facility, date, and what you tapped, if any.',
              ),
            ),
            const SizedBox(height: SR.space8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _sending ? null : _pick,
                icon: const Icon(Icons.attach_file_rounded, size: 18),
                label: Text(_attachment?.name ?? 'Attach a screenshot'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: SR.space8),
              Text(
                _error!,
                key: const Key('support-error'),
                style: SrType.bodySm(color: context.srColors.red),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _sending ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('support-submit'),
        onPressed: _sending ? null : _submit,
        child: Text(_sending ? 'Sending…' : 'Send ticket'),
      ),
    ],
  );
}
