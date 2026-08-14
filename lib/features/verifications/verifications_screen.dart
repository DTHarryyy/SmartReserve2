import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/verification.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/queue_shell.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';

class VerificationsScreen extends StatelessWidget {
  const VerificationsScreen({super.key});

  static const _tabs = [
    (VerificationDecision.pending, 'Awaiting review'),
    (VerificationDecision.approved, 'Verified'),
    (VerificationDecision.changesRequested, 'Document asked'),
    (VerificationDecision.rejected, 'Rejected'),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final stacked = MediaQuery.sizeOf(context).width < SR.desktopMin;
    final rows = state.visibleVerifications;
    final selected = state.selectedVerification;

    return QueueShell(
      stacked: stacked,
      panelOpen: selected != null,
      onClosePanel: () => state.selectVerification(null),
      panel: selected == null
          ? null
          : _VerificationPanel(
              state: state,
              submission: selected,

              showBack: false,
              onBack: () => state.selectVerification(null),
            ),
      list: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              spacing: 6,
              children: [
                for (final (decision, label) in _tabs)
                  QueueTab(
                    label: label,
                    count: state.verifications
                        .where((v) => v.decision == decision)
                        .length,
                    selected: state.verificationTab == decision,
                    onTap: () => state.setVerificationTab(decision),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          if (rows.isEmpty)
            _empty(state)
          else
            for (final submission in rows)
              _QueueRow(
                submission: submission,
                selected: state.selectedVerificationId == submission.id,
                checked: state.selectedVerificationIds.contains(submission.id),
                onOpen: () => state.selectVerification(submission.id),
                onToggle: (extend) => state.toggleVerificationSelection(
                  submission.id,
                  extend: extend,
                ),
              ),

          const SizedBox(height: 12),
          Text(
            'Nobody is blocked while they wait — a pending member can browse '
            'and prepare a request. Verifying here releases it.',
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
          state.verificationTab == VerificationDecision.pending
              ? 'Nobody is waiting'
              : 'Nothing here yet',
          style: sans(14, w: 600),
        ),
        const SizedBox(height: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            state.verificationTab == VerificationDecision.pending
                ? 'Every campus claim has been decided. Documents are reviewed '
                      'each morning, within one business day.'
                : 'Submissions appear here once they reach this state.',
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
    required this.submission,
    required this.selected,
    required this.checked,
    required this.onOpen,
    required this.onToggle,
  });

  final VerificationSubmission submission;
  final bool selected;
  final bool checked;
  final VoidCallback onOpen;

  final ValueChanged<bool> onToggle;

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
                  semanticLabel: 'Select ${submission.name}',
                ),
              ),
              const SizedBox(width: 11),
              Initials(text: submission.initials, size: 30, fontSize: 10),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            submission.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(13, w: 600, tracking: -.01),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          submission.submitted,
                          style: mono(10.5, color: SR.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${submission.kind} · ${submission.unit}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11.5, color: SR.ink4),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          submission.idNumber,
                          style: mono(11, w: 500, color: SR.ink3),
                        ),
                        SrPill(
                          label: submission.documentPath == null
                              ? 'Document deleted'
                              : 'Document submitted',
                          background: submission.documentPath == null
                              ? SR.surfaceSubtle
                              : SR.blueTint,
                          foreground: submission.documentPath == null
                              ? SR.ink4
                              : SR.blueDark,
                          fontSize: 10,
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

class _VerificationPanel extends StatefulWidget {
  const _VerificationPanel({
    required this.state,
    required this.submission,
    required this.showBack,
    required this.onBack,
  });

  final AppState state;
  final VerificationSubmission submission;
  final bool showBack;
  final VoidCallback onBack;

  @override
  State<_VerificationPanel> createState() => _VerificationPanelState();
}

enum _Prompt { none, reject, askDocument }

class _VerificationPanelState extends State<_VerificationPanel> {
  _Prompt _prompt = _Prompt.none;

  @override
  void didUpdateWidget(_VerificationPanel old) {
    super.didUpdateWidget(old);
    if (old.submission.id != widget.submission.id) _prompt = _Prompt.none;
  }

  @override
  Widget build(BuildContext context) {
    final submission = widget.submission;
    final narrow = MediaQuery.sizeOf(context).width < 900;
    final deciding = widget.state.verificationDecisionPending(submission.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.showBack) ...[
                    SrIconButton(
                      glyph: '←',
                      tooltip: 'Back to the queue',
                      size: 32,
                      fontSize: 13,
                      onPressed: widget.onBack,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Initials(text: submission.initials),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          submission.name,
                          style: sans(14.5, w: 600, tracking: -.015),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          submission.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(11, color: SR.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SrPill(
                    label: AppState.verificationLabel(submission.decision),
                    background: switch (submission.decision) {
                      VerificationDecision.approved => SR.greenTint,
                      VerificationDecision.rejected => SR.redTint,
                      VerificationDecision.changesRequested => SR.blueTint,
                      VerificationDecision.pending => SR.amberTint,
                    },
                    foreground: switch (submission.decision) {
                      VerificationDecision.approved => SR.greenDark,
                      VerificationDecision.rejected => SR.red,
                      VerificationDecision.changesRequested => SR.blueDark,
                      VerificationDecision.pending => SR.amber,
                    },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SrCellGrid(
                columns: narrow ? 1 : 2,
                children: [
                  SrKeyCell(label: 'CLAIMED STATUS', value: submission.kind),
                  SrKeyCell(
                    label: 'ID NUMBER',
                    value: submission.idNumber,
                    valueMono: true,
                  ),
                  SrKeyCell(label: 'PROGRAM / UNIT', value: submission.unit),
                  SrKeyCell(label: 'RECEIVED', value: submission.submitted),
                ],
              ),
            ],
          ),
        ),

        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Submitted document',
                style: sans(11, w: 500, color: SR.ink2),
              ),
              const SizedBox(height: 8),
              _DocumentViewer(state: widget.state, submission: submission),
              const SizedBox(height: 7),
              Text(
                submission.documentPath == null
                    ? 'The document was deleted after the final decision.'
                    : 'Visible to internal admins only and deleted after a final decision.',
                style: sans(10.5, height: 1.6, color: SR.muted),
              ),
            ],
          ),
        ),

        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Review the submitted identity document and the applicant details before deciding.',
                style: sans(11.5, height: 1.6, color: SR.ink4),
              ),
              const SizedBox(height: 14),
              if (submission.isPending)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SrButton(
                      label: deciding ? 'Saving…' : 'Verify member',
                      kind: SrButtonKind.primary,
                      fontSize: 12.5,
                      minHeight: 42,
                      onPressed: deciding
                          ? null
                          : () => _confirmApproval(context),
                    ),
                    SrButton(
                      label: 'Ask for a clearer document',
                      fontSize: 12.5,
                      minHeight: 42,
                      onPressed: deciding
                          ? null
                          : () => setState(() => _prompt = _Prompt.askDocument),
                    ),
                    SrButton(
                      label: 'Reject',
                      kind: SrButtonKind.danger,
                      fontSize: 12.5,
                      minHeight: 42,
                      onPressed: deciding
                          ? null
                          : () => setState(() => _prompt = _Prompt.reject),
                    ),
                  ],
                )
              else
                _decided(submission),

              if (_prompt == _Prompt.reject)
                ReasonBox(
                  title: 'Reason for rejection',
                  placeholder:
                      'The applicant sees this verbatim and may submit a new document.',
                  confirmLabel: 'Reject and notify',
                  onCancel: () => setState(() => _prompt = _Prompt.none),
                  onConfirm: (reason) {
                    setState(() => _prompt = _Prompt.none);
                    widget.state.decideVerification(
                      submission.id,
                      VerificationDecision.rejected,
                      reason: reason,
                    );
                  },
                ),
              if (_prompt == _Prompt.askDocument)
                ReasonBox(
                  tone: ReasonTone.neutral,
                  title: 'What is wrong with the document',
                  placeholder:
                      'This is not a rejection — their place in the queue is '
                      'kept. Say what to photograph again.',
                  confirmLabel: 'Ask and notify',
                  onCancel: () => setState(() => _prompt = _Prompt.none),
                  onConfirm: (reason) {
                    setState(() => _prompt = _Prompt.none);
                    widget.state.decideVerification(
                      submission.id,
                      VerificationDecision.changesRequested,
                      reason: reason,
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmApproval(BuildContext context) async {
    final submission = widget.submission;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x8010141A),
      builder: (dialogContext) => SrConfirmDialog(
        title: 'Verify this campus member?',
        content: Text(
          '${submission.name} will be marked verified. The submitted private '
          'document is permanently deleted after this decision.',
        ),
        confirmLabel: 'Verify member',
        onCancel: () => Navigator.of(dialogContext).pop(false),
        onConfirm: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed ?? false) {
      await widget.state.decideVerification(
        submission.id,
        VerificationDecision.approved,
      );
    }
  }

  Widget _decided(VerificationSubmission submission) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${AppState.verificationLabel(submission.decision)}'
        '${submission.decidedAt == null ? '' : ' · ${submission.decidedAt}'}',
        style: sans(12, w: 500, color: SR.ink2),
      ),
      if (submission.reason case final reason?) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: SR.surfaceSubtle,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: SR.hairline),
          ),
          child: Text(
            '“$reason”',
            style: sans(11.5, height: 1.6, color: SR.ink4),
          ),
        ),
      ],
    ],
  );
}

class _DocumentViewer extends StatelessWidget {
  const _DocumentViewer({required this.state, required this.submission});

  final AppState state;
  final VerificationSubmission submission;

  @override
  Widget build(BuildContext context) {
    final path = submission.documentPath;
    if (path == null || state.backend == null) {
      return _message('No document is available.');
    }
    return FutureBuilder(
      future: state.backend!.downloadDocument(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _message('Loading private document…');
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return _message('Document preview is unavailable.');
        }
        final image =
            submission.document.toLowerCase().endsWith('.jpg') ||
            submission.document.toLowerCase().endsWith('.jpeg') ||
            submission.document.toLowerCase().endsWith('.png');
        if (!image) {
          return _message(
            '${submission.document}\nPDF document available for review.',
          );
        }
        return AspectRatio(
          aspectRatio: 16 / 10,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(snapshot.data!, fit: BoxFit.contain),
          ),
        );
      },
    );
  }

  Widget _message(String text) => AspectRatio(
    aspectRatio: 16 / 10,
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: SR.surfaceSubtle,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SR.border),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: sans(11, color: SR.muted),
      ),
    ),
  );
}
