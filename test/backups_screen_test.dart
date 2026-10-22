import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/backups/backups_screen.dart';
import 'package:smartreserve/model/system_backup.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/side_nav.dart';
import 'package:smartreserve/widgets/sr_controls.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SessionProfile _profile(String role) => SessionProfile(
  id: 'admin-1',
  email: 'admin@example.com',
  fullName: 'Admin One',
  role: role,
  campusClaim: null,
  campusId: null,
  unit: null,
  verificationStatus: 'none',
  onboardingComplete: true,
  accountStatus: 'active',
  accountAccessType: role == 'user' ? 'external_guest' : 'administrator',
  mustChangePassword: false,
  createdAt: null,
);

BackendSystemBackup _backup(
  String id, {
  String label = '',
  SystemBackupKind kind = SystemBackupKind.manual,
  int facilities = 6,
  int requests = 120,
  bool compatible = true,
  DateTime? restoredAt,
}) => BackendSystemBackup(
  id: id,
  label: label,
  kind: kind,
  formatVersion: 1,
  schemaVersion: '20261022100000',
  tableCounts: {'facilities': facilities, 'reservation_requests': requests},
  sizeBytes: 2048,
  checksum: 'sum-$id',
  createdByName: 'Admin One',
  createdAt: DateTime(2026, 10, 22, 9, 30),
  restoredAt: restoredAt,
  schemaCompatible: compatible,
);

class _Backend implements SmartReserveBackend {
  List<BackendSystemBackup> stored = [];
  final createdLabels = <String>[];
  final restores = <({String id, String reason})>[];
  final deleted = <String>[];
  Object? restoreError;

  @override
  Future<List<BackendSystemBackup>> systemBackups() async => List.of(stored);

  @override
  Future<BackendSystemBackup> createSystemBackup({String label = ''}) async {
    createdLabels.add(label);
    final created = _backup('new-${createdLabels.length}', label: label);
    stored = [created, ...stored];
    return created;
  }

  @override
  Future<BackendBackupRestoreResult> restoreSystemBackup(
    String backupId, {
    required String reason,
  }) async {
    if (restoreError case final error?) throw error;
    restores.add((id: backupId, reason: reason));
    stored = [
      _backup(
        'safety-${restores.length}',
        label: 'Before restoring $backupId',
        kind: SystemBackupKind.preRestore,
      ),
      ...stored,
    ];
    return BackendBackupRestoreResult(
      backupId: backupId,
      safetyBackupId: 'safety-${restores.length}',
      restoredCounts: const {'facilities': 6, 'reservation_requests': 120},
      skippedRows: const {},
      profilesUpserted: 2,
      profilesSkippedMissingAuth: 0,
      profilesKeptNewer: 0,
      durationMs: 12,
    );
  }

  @override
  Future<void> deleteSystemBackup(String backupId, {String reason = ''}) async {
    deleted.add(backupId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

class _State extends AppState {
  _State() : super(useDemoData: false);

  final refreshed = <String>[];

  @override
  Future<void> refreshFacilities() async => refreshed.add('facilities');
  @override
  Future<void> refreshReservations() async => refreshed.add('reservations');
  @override
  Future<void> refreshNotifications({bool silent = false}) async =>
      refreshed.add('notifications');
  @override
  Future<void> refreshAccounts() async => refreshed.add('accounts');
  @override
  Future<void> refreshVerifications() async => refreshed.add('verifications');
  @override
  Future<void> refreshAudit({AuditQuery? query}) async =>
      refreshed.add('audit');
}

void scenario(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      // The toast owns a 4 second timer that would outlive the test.
      _current?.toasts.dismiss();
    }
  });
}

_State? _current;

void main() {
  late _Backend backend;
  late _State state;

  setUp(() {
    backend = _Backend();
    state = _State()
      ..backend = backend
      ..sessionProfile = _profile('internal_admin');
    _current = state;
  });

  tearDown(() => state.dispose());

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: SrThemeData.light(),
        home: AppScope(
          state: state,
          child: const Scaffold(body: BackupsScreen()),
        ),
      ),
    );
    await tester.pump();
  }

  bool enabled(WidgetTester tester, Key key) =>
      tester.widget<SrButton>(find.byKey(key)).onPressed != null;

  Future<void> openRestoreDialog(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('backup-restore-$id')));
    await tester.pumpAndSettle();
  }

  const restoreButton = ValueKey('restore-backup-confirm');

  scenario('lists backups with their kind, records and size', (tester) async {
    backend.stored = [
      _backup('a', label: 'Before semester'),
      _backup('b', kind: SystemBackupKind.automatic, requests: 1180),
      _backup('c', label: 'Safety copy', kind: SystemBackupKind.preRestore),
    ];
    await state.refreshBackups();
    await pumpScreen(tester);

    expect(find.text('Before semester'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Automatic'), findsWidgets);
    expect(find.text('Safety'), findsOneWidget);
    expect(find.text('126 records'), findsNWidgets(2));
    expect(find.text('1,186 records'), findsOneWidget);
    expect(find.text('2.0 KB'), findsNWidgets(3));
  });

  scenario('shows an empty state when there are no backups', (tester) async {
    await state.refreshBackups();
    await pumpScreen(tester);
    expect(find.text('No backups yet'), findsOneWidget);
  });

  scenario('explains that backups need a live connection', (tester) async {
    state.backend = null;
    await pumpScreen(tester);
    expect(find.text('Backups need a live connection'), findsOneWidget);
    expect(enabled(tester, const ValueKey('backups-create')), isFalse);
  });

  for (final role in ['internal_admin', 'external_admin']) {
    scenario('$role can create a backup with a label', (tester) async {
      state.sessionProfile = _profile(role);
      await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('backups-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('create-backup-label')),
        'Before demo',
      );
      await tester.tap(find.byKey(const ValueKey('create-backup-confirm')));
      await tester.pumpAndSettle();

      expect(backend.createdLabels, ['Before demo']);
      expect(find.text('Before demo'), findsOneWidget);
      expect(find.text('Backup created with 126 records.'), findsNothing);
      expect(state.toasts.active?.message.text, contains('126 records'));
    });
  }

  scenario('a restore needs a reason and the exact confirmation word', (
    tester,
  ) async {
    backend.stored = [_backup('a', label: 'Before semester')];
    await state.refreshBackups();
    await pumpScreen(tester);
    await openRestoreDialog(tester, 'a');

    expect(enabled(tester, restoreButton), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-reason')),
      'Rolling back a bad import',
    );
    await tester.pump();
    expect(enabled(tester, restoreButton), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-confirmation')),
      'restore',
    );
    await tester.pump();
    expect(enabled(tester, restoreButton), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-confirmation')),
      'RESTORE',
    );
    await tester.pump();
    expect(enabled(tester, restoreButton), isTrue);

    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-reason')),
      '  ',
    );
    await tester.pump();
    expect(enabled(tester, restoreButton), isFalse);
    expect(backend.restores, isEmpty);
  });

  scenario('restoring runs the restore, reloads data and shows the result', (
    tester,
  ) async {
    backend.stored = [_backup('a', label: 'Before semester')];
    await state.refreshBackups();
    await pumpScreen(tester);
    await openRestoreDialog(tester, 'a');

    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-reason')),
      'Rolling back a bad import',
    );
    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-confirmation')),
      'RESTORE',
    );
    await tester.pump();
    await tester.tap(find.byKey(restoreButton));
    await tester.pumpAndSettle();

    expect(backend.restores, [(id: 'a', reason: 'Rolling back a bad import')]);
    expect(
      state.refreshed,
      containsAll(['facilities', 'reservations', 'notifications', 'accounts']),
    );
    expect(find.text('Backup restored'), findsOneWidget);
    expect(find.textContaining('126 records were restored'), findsOneWidget);
    expect(find.byKey(const ValueKey('restore-result-undo')), findsOneWidget);
    expect(state.lastRestore?.safetyBackupId, 'safety-1');
  });

  scenario('undoing a restore offers the safety backup for restore', (
    tester,
  ) async {
    backend.stored = [_backup('a', label: 'Before semester')];
    await state.refreshBackups();
    await pumpScreen(tester);
    await openRestoreDialog(tester, 'a');
    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-reason')),
      'Rolling back a bad import',
    );
    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-confirmation')),
      'RESTORE',
    );
    await tester.pump();
    await tester.tap(find.byKey(restoreButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('restore-result-undo')));
    await tester.pumpAndSettle();

    expect(find.byKey(restoreButton), findsOneWidget);
    expect(find.text('Before restoring a'), findsWidgets);
    expect(enabled(tester, restoreButton), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-reason')),
      'Undo the restore',
    );
    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-confirmation')),
      'RESTORE',
    );
    await tester.pump();
    await tester.tap(find.byKey(restoreButton));
    await tester.pumpAndSettle();

    expect(backend.restores.map((r) => r.id), ['a', 'safety-1']);
  });

  scenario('a failed restore keeps the dialog open and says why', (
    tester,
  ) async {
    backend.stored = [_backup('a', label: 'Before semester')];
    backend.restoreError = const PostgrestException(
      message: 'Backup failed its integrity check',
      code: '22023',
    );
    await state.refreshBackups();
    await pumpScreen(tester);
    await openRestoreDialog(tester, 'a');
    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-reason')),
      'Rolling back a bad import',
    );
    await tester.enterText(
      find.byKey(const ValueKey('restore-backup-confirmation')),
      'RESTORE',
    );
    await tester.pump();
    await tester.tap(find.byKey(restoreButton));
    await tester.pumpAndSettle();

    expect(find.byKey(restoreButton), findsOneWidget);
    expect(find.text('Backup restored'), findsNothing);
    expect(enabled(tester, restoreButton), isTrue);
    expect(
      state.toasts.active?.message.text,
      'Backup failed its integrity check.',
    );
    expect(state.refreshed, isEmpty);
    expect(state.restoringBackup, isFalse);
  });

  scenario('a backup from an older database version cannot be restored', (
    tester,
  ) async {
    backend.stored = [_backup('old', label: 'Old', compatible: false)];
    await state.refreshBackups();
    await pumpScreen(tester);

    expect(find.text('Older database version'), findsOneWidget);
    expect(enabled(tester, const ValueKey('backup-restore-old')), isFalse);
    expect(enabled(tester, const ValueKey('backup-download-old')), isTrue);
  });

  scenario('deleting asks first, then removes the backup', (tester) async {
    backend.stored = [
      _backup('a', label: 'Keep me'),
      _backup('b', label: 'Drop me'),
    ];
    await state.refreshBackups();
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('backup-delete-b')));
    await tester.pumpAndSettle();
    expect(find.text('Delete backup?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.deleted, isEmpty);
    expect(find.text('Drop me'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup-delete-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete backup'));
    await tester.pumpAndSettle();
    expect(backend.deleted, ['b']);
    expect(find.text('Drop me'), findsNothing);
    expect(find.text('Keep me'), findsOneWidget);
  });

  group('navigation', () {
    for (final role in ['internal_admin', 'external_admin']) {
      scenario('$role sees Backups in the side navigation', (tester) async {
        state.sessionProfile = _profile(role);
        tester.view.physicalSize = const Size(1200, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: SrThemeData.light(),
            home: Scaffold(
              body: SideNav(state: state, onSelect: (_) {}),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('side-nav-item-backups')),
          findsOneWidget,
        );
      });
    }

    test('opening Backups loads the list', () async {
      backend.stored = [_backup('a')];
      state.view = AppView.facilities;
      state.goTo(AppView.backups);
      await Future<void>.delayed(Duration.zero);
      expect(state.view, AppView.backups);
      expect(state.systemBackups.map((b) => b.id), ['a']);
    });

    test('a regular user cannot open Backups', () async {
      state.sessionProfile = _profile('user');
      state.view = AppView.userApp;
      state.goTo(AppView.backups);
      await Future<void>.delayed(Duration.zero);
      expect(state.view, AppView.userApp);
      expect(state.systemBackups, isEmpty);
      expect(await state.createBackup(), isNull);
      expect(backend.createdLabels, isEmpty);
    });
  });
}
