import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/notice.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';

Future<void> showUserDetail(
  BuildContext context, {
  required AppState state,
  required Account account,
}) {
  if (SR.isCompact(MediaQuery.sizeOf(context).width)) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _UserDetailPage(state: state, account: account),
      ),
    );
  }

  return showDialog<void>(
    context: context,
    barrierColor: SR.scrim,
    builder: (_) => _UserDetailDialog(state: state, account: account),
  );
}

enum _Action { none, role, suspend }

class _UserDetailDialog extends StatefulWidget {
  const _UserDetailDialog({
    required this.state,
    required this.account,
    this.embedded = false,
  });

  final AppState state;
  final Account account;
  final bool embedded;

  @override
  State<_UserDetailDialog> createState() => _UserDetailDialogState();
}

class _UserDetailDialogState extends State<_UserDetailDialog> {
  _Action _action = _Action.none;
  final _reason = TextEditingController();
  final _until = TextEditingController();
  final _scrollController = ScrollController();
  final _feedbackKey = GlobalKey();
  AccountRole _roleDraft = AccountRole.user;
  bool _attempted = false;
  bool _busy = false;
  String? _operationError;
  DateTime? _untilDate;

  @override
  void initState() {
    super.initState();
    _roleDraft = widget.account.role;
  }

  @override
  void dispose() {
    _reason.dispose();
    _until.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Account get _account => widget.account;

  Future<void> _perform(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _operationError = null;
    });
    String? error;
    try {
      error = await action();
    } catch (_) {
      error = 'SmartReserve could not complete this account action. Try again.';
      widget.state.showToast(
        const ToastMessage(
          'Account action wasn’t completed.',
          tone: AdvisoryTone.block,
        ),
        duration: const Duration(seconds: 6),
      );
    }
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _operationError = error;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final feedbackContext = _feedbackKey.currentContext;
        if (!mounted || feedbackContext == null) return;
        Scrollable.ensureVisible(
          feedbackContext,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: .85,
        );
      });
      return;
    }
    Navigator.of(context).pop();
  }

  void _openAction(_Action action) {
    setState(() {
      _action = action;
      _attempted = false;
      _operationError = null;
      _reason.clear();
      if (action == _Action.role) _roleDraft = _account.role;
      if (action == _Action.suspend) {
        _untilDate = null;
        _until.clear();
      }
    });
  }

  void _clearOperationError() {
    if (_operationError != null) _operationError = null;
  }

  Future<void> _pickUntil() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _untilDate ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day + 1),
      lastDate: DateTime(now.year + 5, 12, 31),
      helpText: 'Choose suspension lift date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _untilDate = picked;
      _until.text = _dateLabel(picked);
      _clearOperationError();
    });
  }

  static String _dateLabel(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${value.day} ${months[value.month - 1]} ${value.year}';
  }

  String get _invitationNote {
    final sent = _account.invitationSentAt;
    return sent == null
        ? 'Invited — not yet accepted. The link is single-use and expires automatically.'
        : 'Invited — not yet accepted. Sent ${_dateLabel(sent)}. The link is single-use and expires automatically.';
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.state.roleChangeBlockedReason(_account);

    final content = SingleChildScrollView(
      controller: _scrollController,
      padding: widget.embedded ? const EdgeInsets.all(16) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Initials(text: _account.initials, size: 42, fontSize: 13),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _account.name,
                      style: sans(16, w: 600, tracking: -.015),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _account.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(11, color: SR.muted),
                    ),
                    const SizedBox(height: 3),
                    Text(_account.unit, style: sans(11, color: SR.ink4)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SrPill(
                    label: _account.status.label,
                    background: _account.status.background,
                    foreground: _account.status.foreground,
                  ),
                  const SizedBox(height: 5),
                  SrPill(
                    label: _account.verification.label,
                    background: _account.verification.background,
                    foreground: _account.verification.foreground,
                    fontSize: 10,
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 14),
          _Note(
            text: _account.role.privileges,
            background: SR.blueTint2,
            border: SR.blueLine,
            foreground: SR.blueInk,
          ),
          if (_account.role == AccountRole.externalAdmin)
            _Note(
              text:
                  'Cannot see student or faculty documents, the '
                  'verification queue, or campus reservations. External '
                  'clients, rates and invoices only.',
              background: SR.surfaceSubtle,
              border: SR.hairline,
              foreground: SR.ink4,
            ),
          if (_account.isInvited)
            _Note(
              text: _invitationNote,
              background: SR.amberTint,
              border: SR.amberLine,
              foreground: SR.amberTitle,
            ),
          if (_account.status == AccountStatus.suspended)
            _Note(
              text:
                  '${_account.suspendReason ?? 'Suspended.'}'
                  '${_account.suspendUntil == null ? '' : ' Lifts on ${_account.suspendUntil}.'}',
              background: SR.redTint,
              border: SR.redLine,
              foreground: SR.redInk,
            ),

          const SizedBox(height: 12),
          SrCellGrid(
            columns: 2,
            children: [
              SrKeyCell(label: 'ROLE', value: _account.role.label),
              SrKeyCell(
                label: 'ID NUMBER',
                value: _account.idNumber,
                valueMono: true,
              ),
              SrKeyCell(
                label: 'RESERVATIONS',
                value: _account.activityMetricsAvailable
                    ? '${_account.reservations} on record'
                    : '—',
              ),
              SrKeyCell(
                label: 'NO-SHOWS',
                value: _account.activityMetricsAvailable
                    ? '${_account.noShows}'
                    : '—',
                valueColor:
                    _account.activityMetricsAvailable && _account.noShows > 0
                    ? SR.amber
                    : SR.ink,
              ),
              SrKeyCell(label: 'JOINED', value: _account.joined),
              SrKeyCell(label: 'LAST ACTIVE', value: _account.lastActive),
            ],
          ),

          if (blocked != null) ...[
            const SizedBox(height: 12),
            _Note(
              text: blocked,
              background: SR.surfaceSubtle,
              border: SR.hairline,
              foreground: SR.ink4,
            ),
          ],

          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.only(top: 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: SR.divider)),
            ),
            child: _account.isInvited
                ? _inviteActions()
                : _normalActions(blocked),
          ),

          if (_action == _Action.role) _roleForm(),
          if (_action == _Action.suspend) _suspendForm(),
          if (_operationError != null)
            KeyedSubtree(
              key: _feedbackKey,
              child: SrErrorText(_operationError),
            ),

          if (!widget.embedded) ...[
            const SizedBox(height: 12),
            SrButton(
              label: 'Close',
              expand: true,
              minHeight: 40,
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ],
      ),
    );

    if (widget.embedded) return content;
    return SrAdaptiveDialog(
      maxWidth: 560,
      maxHeight: 760,
      padding: const EdgeInsets.all(22),
      child: content,
    );
  }

  Widget _inviteActions() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      SrButton(
        label: 'Resend invitation',
        kind: SrButtonKind.primary,
        fontSize: 12.5,
        minHeight: 40,
        onPressed: _busy
            ? null
            : () => _perform(() => widget.state.resendInvite(_account)),
      ),
      SrButton(
        label: 'Revoke',
        kind: SrButtonKind.danger,
        fontSize: 12.5,
        minHeight: 40,
        onPressed: _busy ? null : _confirmRevoke,
      ),
    ],
  );

  Widget _normalActions(String? blocked) => Row(
    children: [
      Expanded(
        child: SrButton(
          label: 'Change role',
          expand: true,
          fontSize: 12.5,
          minHeight: 40,
          onPressed: blocked != null || _busy
              ? null
              : () => _openAction(_Action.role),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _account.status == AccountStatus.suspended
            ? SrButton(
                label: 'Lift suspension',
                kind: SrButtonKind.primary,
                expand: true,
                fontSize: 12.5,
                minHeight: 40,
                onPressed: _busy
                    ? null
                    : () =>
                          _perform(() => widget.state.liftSuspension(_account)),
              )
            : SrButton(
                label: 'Suspend account',
                kind: SrButtonKind.danger,
                expand: true,
                fontSize: 12.5,
                minHeight: 40,
                onPressed: _account.isSelf || _busy
                    ? null
                    : () => _openAction(_Action.suspend),
              ),
      ),
    ],
  );

  Widget _roleForm() => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: SR.surfaceSubtle,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: SR.hairline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SrLabel('New role'),
        SrSelect<AccountRole>(
          value: _roleDraft,
          items: AccountRole.values,
          semanticLabel: 'New role',
          fontSize: 12.5,
          labelOf: (r) => r.label,
          onChanged: (r) {
            if (r != null) {
              setState(() {
                _roleDraft = r;
                _clearOperationError();
              });
            }
          },
        ),
        if (_attempted && _roleDraft == _account.role)
          const SrErrorText('Choose a different role.'),
        const SizedBox(height: 7),
        Text(
          _roleDraft.privileges,
          style: sans(11, height: 1.55, color: SR.ink4),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SrButton(
              kind: SrButtonKind.primary,
              label: _busy ? 'Saving…' : 'Apply role change',
              onPressed: _busy
                  ? null
                  : () async {
                      if (_roleDraft == _account.role) {
                        setState(() => _attempted = true);
                        return;
                      }
                      await _perform(
                        () => widget.state.changeRole(_account, _roleDraft),
                      );
                    },
            ),
            const SizedBox(width: 8),
            SrButton(
              label: 'Cancel',
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _action = _Action.none;
                      _attempted = false;
                      _operationError = null;
                    }),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _suspendForm() => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: SR.redTint,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: SR.redLine),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Suspend this account', style: sans(12, w: 600, color: SR.redInk)),
        const SizedBox(height: 3),
        Text(
          'New requests are blocked. Reservations already approved stay in the '
          'calendar.',
          style: sans(11.5, height: 1.6, color: SR.redInk2),
        ),
        const SizedBox(height: 12),
        const SrLabel('Reason', required: true),
        SrTextField(
          controller: _reason,
          placeholder: 'The account holder sees this.',
          fontSize: 12.5,
          minLines: 2,
          maxLines: 4,
          hasError: _attempted && _reason.text.trim().isEmpty,
          keyboardType: TextInputType.multiline,
          onChanged: (_) => setState(_clearOperationError),
        ),
        if (_attempted && _reason.text.trim().isEmpty)
          const SrErrorText('The person sees this — say what happened.'),
        const SizedBox(height: 10),
        SrLabel(
          'Lifts on',
          meta: Text(
            'leave blank for indefinite',
            style: sans(11, color: SR.muted),
          ),
        ),
        SrTextField(
          controller: _until,
          placeholder: 'e.g. 31 Aug 2026',
          fontSize: 12.5,
          mono: true,
          readOnly: true,
          onTap: _busy ? null : _pickUntil,
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_untilDate != null)
                IconButton(
                  tooltip: 'Clear lift date',
                  visualDensity: VisualDensity.compact,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _untilDate = null;
                          _until.clear();
                          _clearOperationError();
                        }),
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
              const Icon(Icons.calendar_today_outlined, size: 15),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SrButton(
              kind: SrButtonKind.dangerSolid,
              label: _busy ? 'Saving…' : 'Suspend account',
              onPressed: _busy
                  ? null
                  : () async {
                      if (_reason.text.trim().isEmpty) {
                        setState(() => _attempted = true);
                        return;
                      }
                      await _perform(
                        () => widget.state.suspendAccount(
                          _account,
                          _reason.text.trim(),
                          _untilDate,
                        ),
                      );
                    },
            ),
            const SizedBox(width: 8),
            SrButton(
              label: 'Cancel',
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _action = _Action.none;
                      _attempted = false;
                      _operationError = null;
                    }),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> _confirmRevoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SrConfirmDialog(
        title: 'Revoke this invitation?',
        content: Text(
          '${_account.email} will no longer be able to use the invitation link.',
        ),
        cancelLabel: 'Keep invitation',
        confirmLabel: 'Revoke',
        destructive: true,
        onCancel: () => Navigator.of(dialogContext).pop(false),
        onConfirm: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(() => widget.state.revokeInvite(_account));
    }
  }
}

class _UserDetailPage extends StatelessWidget {
  const _UserDetailPage({required this.state, required this.account});

  final AppState state;
  final Account account;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: SR.surface,
      foregroundColor: SR.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text('Account details', style: sans(16, w: 600)),
      leading: IconButton(
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded),
      ),
    ),
    body: _UserDetailDialog(state: state, account: account, embedded: true),
  );
}

class _Note extends StatelessWidget {
  const _Note({
    required this.text,
    required this.background,
    required this.border,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color border;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: border),
    ),
    child: Text(text, style: sans(11.5, height: 1.6, color: foreground)),
  );
}
