import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/notice.dart';
import '../../model/system_backup.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../util/file_export.dart';
import '../../widgets/record_table.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'backup_dialogs.dart';

/// Create, download, upload, restore and delete system backups.
class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key});

  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  Future<void> _create(AppState state) async {
    final label = await showCreateBackupDialog(context);
    if (label == null || !mounted) return;
    await state.createBackup(label: label);
  }

  Future<void> _download(AppState state, BackendSystemBackup backup) async {
    final json = await state.backupPayload(backup);
    if (json == null || !mounted) return;
    final result = await saveTextFile(
      baseName: 'smartreserve-backup',
      extension: 'json',
      contents: json,
    );
    if (!mounted) return;
    if (!result.ok) {
      state.showToast(
        const ToastMessage(
          "The backup couldn't be saved. Check the destination and try again.",
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    state.showToast(
      ToastMessage(
        result.path == null
            ? 'Backup file saved.'
            : 'Backup file saved to ${result.path}.',
        tone: AdvisoryTone.info,
        action: result.revealSupported
            ? ToastAction(
                label: 'Open',
                onPressed: () => revealInFileExplorer(result.path!),
              )
            : null,
      ),
    );
  }

  Future<void> _upload(AppState state) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final name = picked.name.replaceFirst(RegExp(r'\.json$'), '');
    final imported = await state.importBackup(
      bytes,
      label: name.length > 120 ? name.substring(0, 120) : name,
    );
    if (imported == null || !mounted) return;
    await _restore(state, imported);
  }

  Future<void> _restore(AppState state, BackendSystemBackup backup) async {
    final result = await showRestoreBackupDialog(
      context,
      backup,
      onRestore: (reason) => state.restoreBackup(backup, reason),
    );
    if (result == null || !mounted) return;
    final undo = await showRestoreResultDialog(context, result);
    if (!undo || !mounted) return;
    for (final candidate in state.systemBackups) {
      if (candidate.id == result.safetyBackupId) {
        await _restore(state, candidate);
        return;
      }
    }
  }

  Future<void> _delete(AppState state, BackendSystemBackup backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => SrConfirmDialog(
        title: 'Delete backup?',
        content: Text(
          '"${backup.displayLabel}" from ${formatStamp(backup.createdAt)} '
          'will be permanently deleted. This cannot be undone.',
          style: SrType.body(),
        ),
        confirmLabel: 'Delete backup',
        destructive: true,
        onConfirm: () => Navigator.of(dialogContext).pop(true),
        onCancel: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    if (confirmed != true || !mounted) return;
    await state.deleteBackup(backup);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final busy =
        state.backupBusyId != null ||
        state.creatingBackup ||
        state.restoringBackup;
    final backups = state.systemBackups;

    return SrScrollView(
      padding: SR.pageInsets(width, top: SR.isCompact(width) ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrPageHeader(
            description:
                'Snapshots of facilities, reservations, payments, permits, '
                'feedback, loyalty and accounts.',
            actions: [
              SrButton(
                key: const ValueKey('backups-upload'),
                label: 'Restore from file',
                icon: const Icon(Icons.upload_file_rounded, size: 16),
                onPressed: state.backupsAvailable && !busy
                    ? () => _upload(state)
                    : null,
              ),
              SrButton(
                key: const ValueKey('backups-create'),
                label: state.creatingBackup ? 'Working…' : 'Create backup',
                kind: SrButtonKind.primary,
                icon: const Icon(Icons.add_rounded, size: 16),
                onPressed: state.backupsAvailable && !busy
                    ? () => _create(state)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: SR.space16),
          const _CoverageNote(),
          const SizedBox(height: SR.space16),
          if (!state.backupsAvailable)
            const ListEmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Backups need a live connection',
              body:
                  'Backups are stored in the SmartReserve database, so they '
                  'are unavailable in offline demo mode.',
            )
          else if (state.backupsError case final error?)
            SrErrorState(
              title: "Backups couldn't load",
              message: error,
              onRetry: state.refreshBackups,
            )
          else if (state.backupsLoading && backups.isEmpty)
            const SrLoadingState(message: 'Loading backups…')
          else if (backups.isEmpty)
            const ListEmptyState(
              icon: Icons.backup_rounded,
              title: 'No backups yet',
              body:
                  'Create the first backup now. Automatic backups also run '
                  'every night.',
            )
          else ...[
            if (state.backupsLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: SR.space8),
                child: LinearProgressIndicator(),
              ),
            for (final backup in backups)
              Padding(
                padding: const EdgeInsets.only(bottom: SR.space12),
                child: _BackupCard(
                  backup: backup,
                  working: state.backupBusyId == backup.id,
                  enabled: !busy,
                  onDownload: () => _download(state, backup),
                  onRestore: () => _restore(state, backup),
                  onDelete: () => _delete(state, backup),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CoverageNote extends StatelessWidget {
  const _CoverageNote();

  @override
  Widget build(BuildContext context) => SrCard(
    level: SrCardLevel.tinted,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 18, color: SrTone.info.solid),
        const SizedBox(width: SR.space12),
        Expanded(
          child: Text(
            'Uploaded files such as photos and PDFs are not included. '
            'Restoring replaces current records with the backup\'s and saves '
            'a safety backup first. Automatic backups run every night at '
            '2:15 AM and the latest 7 are kept. Downloaded files contain '
            'every reservation, so store them securely.',
            style: SrType.bodySm(),
          ),
        ),
      ],
    ),
  );
}

SrTone _toneFor(SystemBackupKind kind) => switch (kind) {
  SystemBackupKind.manual => SrTone.brand,
  SystemBackupKind.automatic => SrTone.neutral,
  SystemBackupKind.preRestore => SrTone.warning,
  SystemBackupKind.uploaded => SrTone.info,
};

class _BackupCard extends StatelessWidget {
  const _BackupCard({
    required this.backup,
    required this.working,
    required this.enabled,
    required this.onDownload,
    required this.onRestore,
    required this.onDelete,
  });

  final BackendSystemBackup backup;
  final bool working;
  final bool enabled;
  final VoidCallback onDownload;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final restoredAt = backup.restoredAt;
    return SrCard(
      key: ValueKey('backup-${backup.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(backup.displayLabel, style: SrType.subhead()),
                    const SizedBox(height: SR.space4),
                    Text(
                      '${formatStamp(backup.createdAt)} · ${backup.createdByName}',
                      style: SrType.bodySm(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SR.space8),
              SrStatusChip(
                label: backup.kind.label,
                tone: _toneFor(backup.kind),
              ),
            ],
          ),
          const SizedBox(height: SR.space12),
          Wrap(
            spacing: SR.space16,
            runSpacing: SR.space6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${formatCount(backup.totalRows)} records',
                style: SrType.caption(),
              ),
              Text(formatBytes(backup.sizeBytes), style: SrType.caption()),
              if (restoredAt != null)
                Text(
                  'Restored ${formatStamp(restoredAt)}'
                  '${backup.restoredByName == null ? '' : ' by ${backup.restoredByName}'}',
                  style: SrType.caption(),
                ),
              if (!backup.schemaCompatible)
                const SrStatusChip(
                  label: 'Older database version',
                  tone: SrTone.warning,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: SR.space12),
          Wrap(
            spacing: SR.space8,
            runSpacing: SR.space8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SrButton(
                key: ValueKey('backup-restore-${backup.id}'),
                label: 'Restore',
                dense: true,
                icon: const Icon(
                  Icons.settings_backup_restore_rounded,
                  size: 16,
                ),
                tooltip: backup.schemaCompatible
                    ? null
                    : 'Taken on an older database version',
                onPressed: enabled && backup.schemaCompatible
                    ? onRestore
                    : null,
              ),
              SrButton(
                key: ValueKey('backup-download-${backup.id}'),
                label: 'Download',
                dense: true,
                kind: SrButtonKind.ghost,
                icon: const Icon(Icons.download_rounded, size: 16),
                onPressed: enabled ? onDownload : null,
              ),
              SrButton(
                key: ValueKey('backup-delete-${backup.id}'),
                label: 'Delete',
                dense: true,
                kind: SrButtonKind.danger,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                onPressed: enabled ? onDelete : null,
              ),
              if (working)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
