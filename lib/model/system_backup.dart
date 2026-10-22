import 'dart:convert';
import 'dart:typed_data';

/// Largest backup file the app will read or upload. The server enforces the
/// same limit; checking here gives a fast, friendly message.
const maxBackupFileBytes = 50 * 1024 * 1024;

const backupFormat = 'smartreserve-backup';
const backupFormatVersion = 1;

enum SystemBackupKind {
  manual('manual', 'Manual'),
  automatic('automatic', 'Automatic'),
  preRestore('pre_restore', 'Safety'),
  uploaded('uploaded', 'Uploaded');

  const SystemBackupKind(this.wire, this.label);

  final String wire;
  final String label;

  static SystemBackupKind fromWire(String? value) => values.firstWhere(
    (kind) => kind.wire == value,
    orElse: () => SystemBackupKind.manual,
  );
}

Map<String, int> _counts(Object? value) => {
  if (value is Map)
    for (final entry in value.entries)
      '${entry.key}': (entry.value as num?)?.toInt() ?? 0,
};

/// A backup as the app lists it. The payload never travels with this record;
/// it is fetched separately when a person downloads the backup.
class BackendSystemBackup {
  const BackendSystemBackup({
    required this.id,
    required this.label,
    required this.kind,
    required this.formatVersion,
    required this.schemaVersion,
    required this.tableCounts,
    required this.sizeBytes,
    required this.checksum,
    required this.createdByName,
    required this.createdAt,
    this.restoredAt,
    this.restoredByName,
    this.schemaCompatible = true,
  });

  final String id;
  final String label;
  final SystemBackupKind kind;
  final int formatVersion;
  final String schemaVersion;
  final Map<String, int> tableCounts;
  final int sizeBytes;
  final String checksum;
  final String createdByName;
  final DateTime createdAt;
  final DateTime? restoredAt;
  final String? restoredByName;

  /// False when the database has been migrated since this backup was taken;
  /// such a backup can no longer be restored.
  final bool schemaCompatible;

  int get totalRows => tableCounts.values.fold(0, (sum, n) => sum + n);

  String get displayLabel => label.trim().isEmpty ? kind.label : label;

  factory BackendSystemBackup.fromJson(Map<String, dynamic> json) =>
      BackendSystemBackup(
        id: '${json['id']}',
        label: '${json['label'] ?? ''}',
        kind: SystemBackupKind.fromWire(json['kind'] as String?),
        formatVersion: (json['format_version'] as num?)?.toInt() ?? 1,
        schemaVersion: '${json['schema_version'] ?? ''}',
        tableCounts: _counts(json['table_counts']),
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        checksum: '${json['checksum'] ?? ''}',
        createdByName: '${json['created_by_name'] ?? ''}',
        createdAt: DateTime.parse('${json['created_at']}').toLocal(),
        restoredAt: json['restored_at'] == null
            ? null
            : DateTime.parse('${json['restored_at']}').toLocal(),
        restoredByName: json['restored_by_name'] as String?,
        schemaCompatible: json['schema_compatible'] as bool? ?? true,
      );
}

class BackendBackupRestoreResult {
  const BackendBackupRestoreResult({
    required this.backupId,
    required this.safetyBackupId,
    required this.restoredCounts,
    required this.skippedRows,
    required this.profilesUpserted,
    required this.profilesSkippedMissingAuth,
    required this.profilesKeptNewer,
    required this.durationMs,
  });

  final String backupId;

  /// Snapshot of the data as it was just before the restore. Restoring it
  /// undoes the restore.
  final String safetyBackupId;
  final Map<String, int> restoredCounts;
  final Map<String, int> skippedRows;
  final int profilesUpserted;
  final int profilesSkippedMissingAuth;
  final int profilesKeptNewer;
  final int durationMs;

  int get totalRestored => restoredCounts.values.fold(0, (sum, n) => sum + n);
  int get totalSkipped => skippedRows.values.fold(0, (sum, n) => sum + n);

  factory BackendBackupRestoreResult.fromJson(Map<String, dynamic> json) {
    final profiles = json['profiles'] is Map
        ? Map<String, dynamic>.from(json['profiles'] as Map)
        : const <String, dynamic>{};
    return BackendBackupRestoreResult(
      backupId: '${json['backup_id']}',
      safetyBackupId: '${json['safety_backup_id']}',
      restoredCounts: _counts(json['restored_counts']),
      skippedRows: _counts(json['skipped_rows']),
      profilesUpserted: (profiles['upserted'] as num?)?.toInt() ?? 0,
      profilesSkippedMissingAuth:
          (profiles['skipped_missing_auth'] as num?)?.toInt() ?? 0,
      profilesKeptNewer: (profiles['kept_newer'] as num?)?.toInt() ?? 0,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

sealed class BackupFileCheck {
  const BackupFileCheck();
}

final class BackupFileValid extends BackupFileCheck {
  const BackupFileValid({
    required this.payload,
    required this.capturedAt,
    required this.schemaVersion,
    required this.tableCounts,
  });

  final Map<String, dynamic> payload;
  final DateTime capturedAt;
  final String schemaVersion;
  final Map<String, int> tableCounts;

  int get totalRows => tableCounts.values.fold(0, (sum, n) => sum + n);
}

final class BackupFileInvalid extends BackupFileCheck {
  const BackupFileInvalid(this.message);

  final String message;
}

/// Checks that [bytes] look like a SmartReserve backup before they are sent
/// anywhere. The server validates again; this only fails fast with a message
/// a person can act on.
BackupFileCheck checkBackupFile(Uint8List bytes) {
  const notABackup = BackupFileInvalid(
    'This file is not a SmartReserve backup.',
  );
  if (bytes.isEmpty) return const BackupFileInvalid('The file is empty.');
  if (bytes.length > maxBackupFileBytes) {
    return const BackupFileInvalid('The file is larger than 50 MB.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return const BackupFileInvalid('The file is not valid JSON.');
  }
  if (decoded is! Map) return notABackup;
  final payload = Map<String, dynamic>.from(decoded);
  if (payload['format'] != backupFormat) return notABackup;
  if (payload['format_version'] != backupFormatVersion) {
    return BackupFileInvalid(
      'This backup uses format version ${payload['format_version']}, which '
      'this app cannot restore.',
    );
  }
  final schemaVersion = '${payload['schema_version'] ?? ''}';
  if (schemaVersion.isEmpty) {
    return const BackupFileInvalid('The backup is missing its schema version.');
  }
  final capturedAt = DateTime.tryParse('${payload['captured_at']}');
  if (capturedAt == null) {
    return const BackupFileInvalid('The backup is missing its capture time.');
  }
  final tables = payload['tables'];
  if (tables is! Map) {
    return const BackupFileInvalid('The backup has no table data.');
  }
  final counts = <String, int>{};
  for (final entry in tables.entries) {
    final rows = entry.value;
    if (rows is! List || rows.any((row) => row is! Map)) {
      return BackupFileInvalid(
        'The data for "${entry.key}" is not a list of records.',
      );
    }
    counts['${entry.key}'] = rows.length;
  }
  return BackupFileValid(
    payload: payload,
    capturedAt: capturedAt.toLocal(),
    schemaVersion: schemaVersion,
    tableCounts: counts,
  );
}
