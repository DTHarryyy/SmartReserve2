import 'package:flutter/material.dart';

import '../../model/system_backup.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';

/// The word a person must type before a restore will run. The server checks
/// it too, so a stale or scripted client cannot skip the step.
const restoreConfirmationWord = 'RESTORE';

const minRestoreReasonLength = 3;

String formatCount(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String tableLabel(String table) => table.replaceAll('_', ' ');

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.title,
    required this.child,
    required this.actions,
    this.onClose,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          SR.space24,
          SR.space16,
          SR.space12,
          SR.space8,
        ),
        child: Row(
          children: [
            Expanded(child: Text(title, style: SrType.subhead())),
            IconButton(
              tooltip: 'Close',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ],
        ),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            SR.space24,
            SR.space4,
            SR.space24,
            SR.space16,
          ),
          child: child,
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(
          horizontal: SR.space24,
          vertical: SR.space12,
        ),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.srColors.border)),
        ),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: actions,
        ),
      ),
    ],
  );
}

/// Asks for an optional label. Resolves to the label (possibly empty), or
/// null when cancelled.
Future<String?> showCreateBackupDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _CreateBackupDialog(),
    );

class _CreateBackupDialog extends StatefulWidget {
  const _CreateBackupDialog();

  @override
  State<_CreateBackupDialog> createState() => _CreateBackupDialogState();
}

class _CreateBackupDialogState extends State<_CreateBackupDialog> {
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_label.text.trim());

  @override
  Widget build(BuildContext context) => SrAdaptiveDialog(
    maxWidth: 480,
    maxHeight: 420,
    child: _DialogShell(
      title: 'Create backup',
      onClose: () => Navigator.of(context).pop(),
      actions: [
        SrButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SrButton(
          key: const ValueKey('create-backup-confirm'),
          label: 'Create backup',
          kind: SrButtonKind.primary,
          onPressed: _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saves a snapshot of facilities, reservations, payments, permits, '
            'feedback, loyalty and accounts. Uploaded photos and documents are '
            'not included.',
            style: SrType.bodySm(),
          ),
          const SizedBox(height: SR.space16),
          const SrLabel('Label', meta: Text('Optional')),
          const SizedBox(height: SR.space6),
          SrTextField(
            key: const ValueKey('create-backup-label'),
            controller: _label,
            placeholder: 'e.g. Before semester rollover',
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
  );
}

/// Confirms and runs a restore. [onRestore] performs it and resolves to the
/// result, or null when it failed (the caller has already shown why); the
/// dialog stays open then so the person can retry.
Future<BackendBackupRestoreResult?> showRestoreBackupDialog(
  BuildContext context,
  BackendSystemBackup backup, {
  required Future<BackendBackupRestoreResult?> Function(String reason)
  onRestore,
}) => showDialog<BackendBackupRestoreResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _RestoreBackupDialog(backup: backup, onRestore: onRestore),
);

class _RestoreBackupDialog extends StatefulWidget {
  const _RestoreBackupDialog({required this.backup, required this.onRestore});

  final BackendSystemBackup backup;
  final Future<BackendBackupRestoreResult?> Function(String reason) onRestore;

  @override
  State<_RestoreBackupDialog> createState() => _RestoreBackupDialogState();
}

class _RestoreBackupDialogState extends State<_RestoreBackupDialog> {
  final _reason = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _ready =>
      widget.backup.schemaCompatible &&
      _reason.text.trim().length >= minRestoreReasonLength &&
      _confirm.text == restoreConfirmationWord;

  Future<void> _restore() async {
    if (!_ready || _busy) return;
    setState(() => _busy = true);
    final result = await widget.onRestore(_reason.text.trim());
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop(result);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final backup = widget.backup;
    final colors = context.srColors;
    final tables = [
      for (final entry in backup.tableCounts.entries)
        if (entry.value > 0) entry,
    ]..sort((a, b) => b.value.compareTo(a.value));
    return PopScope(
      canPop: !_busy,
      child: SrAdaptiveDialog(
        maxWidth: 560,
        maxHeight: 720,
        child: _DialogShell(
          title: 'Restore backup',
          onClose: _busy ? null : () => Navigator.of(context).pop(),
          actions: [
            SrButton(
              label: 'Cancel',
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
            SrButton(
              key: const ValueKey('restore-backup-confirm'),
              label: _busy ? 'Restoring…' : 'Restore backup',
              kind: SrButtonKind.dangerSolid,
              onPressed: _ready && !_busy ? _restore : null,
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(backup.displayLabel, style: SrType.subhead()),
              const SizedBox(height: SR.space4),
              Text(
                '${backup.kind.label} backup from ${formatStamp(backup.createdAt)} '
                'by ${backup.createdByName} · ${formatCount(backup.totalRows)} '
                'records',
                style: SrType.bodySm(),
              ),
              const SizedBox(height: SR.space16),
              Container(
                padding: const EdgeInsets.all(SR.space12),
                decoration: BoxDecoration(
                  color: colors.redTint,
                  borderRadius: BorderRadius.circular(SR.rMd),
                  border: Border.all(color: colors.redLine),
                ),
                child: Text(
                  'Facilities, reservations, payments, permits, feedback, '
                  'loyalty, notifications and accounts will be replaced with '
                  "this backup's contents. Anything changed after "
                  '${formatStamp(backup.createdAt)} will be removed. A safety '
                  'backup of the current data is saved first, so you can undo '
                  'this. The system is briefly unavailable while it runs.',
                  style: SrType.bodySm(color: colors.red),
                ),
              ),
              if (!backup.schemaCompatible) ...[
                const SizedBox(height: SR.space12),
                Text(
                  'This backup was taken on an older database version and can '
                  'no longer be restored.',
                  style: SrType.bodySm(color: colors.red),
                ),
              ],
              if (tables.isNotEmpty)
                Material(
                  type: MaterialType.transparency,
                  child: Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: Text(
                        'Records in this backup',
                        style: SrType.bodySm(w: 600),
                      ),
                      children: [
                        for (final entry in tables)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    tableLabel(entry.key),
                                    style: SrType.caption(),
                                  ),
                                ),
                                Text(
                                  formatCount(entry.value),
                                  style: SrType.code(),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: SR.space12),
              const SrLabel('Reason', required: true),
              const SizedBox(height: SR.space6),
              SrTextField(
                key: const ValueKey('restore-backup-reason'),
                controller: _reason,
                placeholder: 'Why are you restoring this backup?',
                readOnly: _busy,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: SR.space12),
              const SrLabel('Type $restoreConfirmationWord to confirm'),
              const SizedBox(height: SR.space6),
              SrTextField(
                key: const ValueKey('restore-backup-confirmation'),
                controller: _confirm,
                placeholder: restoreConfirmationWord,
                mono: true,
                readOnly: _busy,
                onChanged: (_) => setState(() {}),
              ),
              if (_busy) ...[
                const SizedBox(height: SR.space16),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Summarises a finished restore. Resolves to true when the person asks to
/// undo it.
Future<bool> showRestoreResultDialog(
  BuildContext context,
  BackendBackupRestoreResult result,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _RestoreResultDialog(result: result),
    ) ??
    false;

class _RestoreResultDialog extends StatelessWidget {
  const _RestoreResultDialog({required this.result});

  final BackendBackupRestoreResult result;

  @override
  Widget build(BuildContext context) {
    final skipped = [
      for (final entry in result.skippedRows.entries)
        if (entry.value > 0) entry,
    ];
    return SrAdaptiveDialog(
      maxWidth: 520,
      maxHeight: 620,
      child: _DialogShell(
        title: 'Backup restored',
        onClose: () => Navigator.of(context).pop(false),
        actions: [
          SrButton(
            key: const ValueKey('restore-result-undo'),
            label: 'Undo this restore',
            onPressed: () => Navigator.of(context).pop(true),
          ),
          SrButton(
            label: 'Done',
            kind: SrButtonKind.primary,
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatCount(result.totalRestored)} records were restored in '
              '${result.durationMs} ms.',
              style: SrType.body(),
            ),
            const SizedBox(height: SR.space8),
            Text(
              'A safety backup of the data as it was just before this restore '
              'was saved. Choose "Undo this restore" to go back to it.',
              style: SrType.bodySm(),
            ),
            if (result.profilesKeptNewer > 0) ...[
              const SizedBox(height: SR.space12),
              Text(
                '${result.profilesKeptNewer} account'
                '${result.profilesKeptNewer == 1 ? ' was' : 's were'} created '
                'after this backup and ${result.profilesKeptNewer == 1 ? 'was' : 'were'} kept.',
                style: SrType.bodySm(),
              ),
            ],
            if (skipped.isNotEmpty) ...[
              const SizedBox(height: SR.space12),
              Text(
                'Some records could not be restored because the account they '
                'belong to no longer exists:',
                style: SrType.bodySm(color: context.srColors.amber),
              ),
              const SizedBox(height: SR.space4),
              for (final entry in skipped)
                Text(
                  '${tableLabel(entry.key)}: ${formatCount(entry.value)}',
                  style: SrType.caption(),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
