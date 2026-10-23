import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/system_backup.dart';
import 'package:smartreserve/util/backend_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Uint8List _bytes(Object? json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, dynamic> _validFile() => {
  'format': 'smartreserve-backup',
  'format_version': 1,
  'schema_version': '20261022100000',
  'captured_at': '2026-10-22T08:15:00Z',
  'tables': {
    'facilities': [
      {'id': 'f1'},
      {'id': 'f2'},
    ],
    'reservation_requests': [
      {'id': 'r1'},
    ],
    'loyalty_rewards': <Object>[],
  },
};

String _invalid(Uint8List bytes) {
  final check = checkBackupFile(bytes);
  expect(check, isA<BackupFileInvalid>());
  return (check as BackupFileInvalid).message;
}

void main() {
  group('BackendSystemBackup.fromJson', () {
    Map<String, dynamic> row({String kind = 'manual', Object? restoredAt}) => {
      'id': 'b1',
      'label': 'Before semester',
      'kind': kind,
      'format_version': 1,
      'schema_version': '20261022100000',
      'table_counts': {'facilities': 6, 'reservation_requests': 120},
      'size_bytes': 2048,
      'checksum': 'abc',
      'created_by_name': 'Registrar',
      'created_at': '2026-10-22T08:15:00Z',
      'restored_at': restoredAt,
      'restored_by_name': restoredAt == null ? null : 'Registrar',
      'schema_compatible': true,
    };

    test('reads every field and sums the records', () {
      final backup = BackendSystemBackup.fromJson(row());
      expect(backup.id, 'b1');
      expect(backup.kind, SystemBackupKind.manual);
      expect(backup.totalRows, 126);
      expect(backup.sizeBytes, 2048);
      expect(backup.createdByName, 'Registrar');
      expect(backup.createdAt.toUtc(), DateTime.utc(2026, 10, 22, 8, 15));
      expect(backup.restoredAt, isNull);
      expect(backup.schemaCompatible, isTrue);
    });

    test('maps each wire kind, including pre_restore', () {
      expect(
        BackendSystemBackup.fromJson(row(kind: 'pre_restore')).kind,
        SystemBackupKind.preRestore,
      );
      expect(
        BackendSystemBackup.fromJson(row(kind: 'automatic')).kind,
        SystemBackupKind.automatic,
      );
      expect(
        BackendSystemBackup.fromJson(row(kind: 'uploaded')).kind,
        SystemBackupKind.uploaded,
      );
      expect(SystemBackupKind.preRestore.label, 'Safety');
    });

    test('parses when and by whom it was restored', () {
      final backup = BackendSystemBackup.fromJson(
        row(restoredAt: '2026-10-23T01:00:00Z'),
      );
      expect(backup.restoredAt!.toUtc(), DateTime.utc(2026, 10, 23, 1));
      expect(backup.restoredByName, 'Registrar');
    });

    test('falls back to the kind when there is no label', () {
      final backup = BackendSystemBackup.fromJson(
        row(kind: 'automatic')..['label'] = '  ',
      );
      expect(backup.displayLabel, 'Automatic');
    });

    test('carries the schema compatibility flag', () {
      final backup = BackendSystemBackup.fromJson(
        row()..['schema_compatible'] = false,
      );
      expect(backup.schemaCompatible, isFalse);
    });
  });

  group('BackendBackupRestoreResult.fromJson', () {
    test('reads counts, skips and profile outcomes', () {
      final result = BackendBackupRestoreResult.fromJson({
        'backup_id': 'b1',
        'safety_backup_id': 's1',
        'restored_counts': {'facilities': 6, 'profiles': 4},
        'skipped_rows': {'profiles': 1},
        'profiles': {'upserted': 4, 'skipped_missing_auth': 1, 'kept_newer': 2},
        'duration_ms': 41,
      });
      expect(result.safetyBackupId, 's1');
      expect(result.totalRestored, 10);
      expect(result.totalSkipped, 1);
      expect(result.profilesUpserted, 4);
      expect(result.profilesSkippedMissingAuth, 1);
      expect(result.profilesKeptNewer, 2);
      expect(result.durationMs, 41);
    });

    test('tolerates a result with no profile section', () {
      final result = BackendBackupRestoreResult.fromJson({
        'backup_id': 'b1',
        'safety_backup_id': 's1',
      });
      expect(result.totalRestored, 0);
      expect(result.profilesKeptNewer, 0);
    });
  });

  group('checkBackupFile', () {
    test('accepts a valid backup and counts its records', () {
      final check = checkBackupFile(_bytes(_validFile()));
      expect(check, isA<BackupFileValid>());
      final valid = check as BackupFileValid;
      expect(valid.schemaVersion, '20261022100000');
      expect(valid.tableCounts['facilities'], 2);
      expect(valid.tableCounts['loyalty_rewards'], 0);
      expect(valid.totalRows, 3);
      expect(valid.capturedAt.toUtc(), DateTime.utc(2026, 10, 22, 8, 15));
      expect(valid.payload['format'], 'smartreserve-backup');
    });

    test('rejects an empty file', () {
      expect(_invalid(Uint8List(0)), 'The file is empty.');
    });

    test('rejects text that is not JSON', () {
      expect(
        _invalid(Uint8List.fromList(utf8.encode('not json {'))),
        'The file is not valid JSON.',
      );
    });

    test('rejects bytes that are not UTF-8', () {
      expect(
        _invalid(Uint8List.fromList([0xff, 0xfe, 0xfd])),
        'The file is not valid JSON.',
      );
    });

    test('rejects JSON that is not an object', () {
      expect(
        _invalid(_bytes([1, 2, 3])),
        'This file is not a SmartReserve backup.',
      );
    });

    test('rejects a different format', () {
      expect(
        _invalid(_bytes(_validFile()..['format'] = 'other')),
        'This file is not a SmartReserve backup.',
      );
    });

    test('rejects an unsupported format version', () {
      expect(
        _invalid(_bytes(_validFile()..['format_version'] = 2)),
        contains('format version 2'),
      );
    });

    test('rejects a missing schema version or capture time', () {
      expect(
        _invalid(_bytes(_validFile()..remove('schema_version'))),
        'The backup is missing its schema version.',
      );
      expect(
        _invalid(_bytes(_validFile()..['captured_at'] = 'yesterday')),
        'The backup is missing its capture time.',
      );
    });

    test('rejects missing or malformed table data', () {
      expect(
        _invalid(_bytes(_validFile()..remove('tables'))),
        'The backup has no table data.',
      );
      expect(
        _invalid(_bytes(_validFile()..['tables'] = [])),
        'The backup has no table data.',
      );
      expect(
        _invalid(_bytes(_validFile()..['tables'] = {'facilities': 'nope'})),
        'The data for "facilities" is not a list of records.',
      );
      expect(
        _invalid(
          _bytes(
            _validFile()
              ..['tables'] = {
                'facilities': [1, 2],
              },
          ),
        ),
        'The data for "facilities" is not a list of records.',
      );
    });

    test('rejects a file over the size limit', () {
      expect(
        _invalid(Uint8List(maxBackupFileBytes + 1)),
        'The file is larger than 50 MB.',
      );
    });
  });

  group('systemBackupMessage', () {
    test('explains a restore that is already running', () {
      expect(
        systemBackupMessage(
          const PostgrestException(
            message: 'Another restore is in progress',
            code: '55P03',
          ),
        ),
        'Another restore is already running. Try again in a minute.',
      );
    });

    test('explains a backup that no longer exists', () {
      expect(
        systemBackupMessage(
          const PostgrestException(message: 'Backup not found', code: 'P0002'),
        ),
        'That backup no longer exists.',
      );
    });

    test('passes the database message through for validation failures', () {
      expect(
        systemBackupMessage(
          const PostgrestException(
            message: 'Backup failed its integrity check',
            code: '22023',
          ),
        ),
        'Backup failed its integrity check.',
      );
      expect(
        systemBackupMessage(
          const PostgrestException(
            message: 'Administrator access required',
            code: '42501',
          ),
        ),
        'Administrator access required.',
      );
    });
  });
}
