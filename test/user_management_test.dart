import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/users/invite_dialog.dart';
import 'package:smartreserve/model/account.dart';
import 'package:smartreserve/widgets/sr_controls.dart';

void main() {
  group('production user management', () {
    test('loads real accounts instead of seeded accounts', () async {
      final backend = _FakeUserBackend();
      final state = AppState(useDemoData: false)..configureBackend(backend);

      await state.applyBackendProfile(_adminProfile);

      expect(state.accounts.map((account) => account.id), [
        'admin-id',
        'user-id',
      ]);
      expect(state.accounts.last.name, 'Live Student');
      expect(state.accounts.last.activityMetricsAvailable, isFalse);
      expect(state.accounts.last.lastActive, isNotEmpty);
      expect(state.accountsError, isNull);
      state.dispose();
      await backend.close();
    });

    test('a confirmed invite is inserted into the live account list', () async {
      final backend = _FakeUserBackend();
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);

      final error = await state.inviteAdmin(
        'new.admin@csu.edu.ph',
        AccountRole.internalAdmin,
        'Help with approvals',
      );

      expect(error, isNull);
      expect(state.accounts.first.email, 'new.admin@csu.edu.ph');
      expect(state.accounts.first.status, AccountStatus.invited);
      expect(backend.actions, contains('invite'));
      state.dispose();
      await backend.close();
    });

    test('a created administrator returns one-time credentials', () async {
      final backend = _FakeUserBackend();
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);

      final result = await state.createAdministrator(
        'new.admin@csu.edu.ph',
        AccountRole.internalAdmin,
        'Registrar coverage',
      );

      expect(result.error, isNull);
      expect(result.credentials?.email, 'new.admin@csu.edu.ph');
      expect(result.credentials?.temporaryPassword, isNotEmpty);
      expect(state.accounts.first.status, AccountStatus.active);
      expect(backend.actions, contains('create_admin'));
      state.dispose();
      await backend.close();
    });

    test('server failures do not add an invitation', () async {
      final backend = _FakeUserBackend()
        ..inviteFailure = 'Email service unavailable';
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);
      final before = state.accounts.length;

      final error = await state.inviteAdmin(
        'failed.admin@csu.edu.ph',
        AccountRole.externalAdmin,
        '',
      );

      expect(error, contains('Email service unavailable'));
      expect(state.accounts, hasLength(before));
      state.dispose();
      await backend.close();
    });

    test('persisted account actions replace the authoritative row', () async {
      final backend = _FakeUserBackend();
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);
      var account = state.accounts.last;

      expect(
        await state.changeRole(account, AccountRole.faculty, 'Appointment'),
        isNull,
      );
      account = state.accounts.firstWhere((item) => item.id == 'user-id');
      expect(account.role, AccountRole.faculty);

      expect(
        await state.suspendAccount(account, 'Repeated no-shows', null),
        isNull,
      );
      account = state.accounts.firstWhere((item) => item.id == 'user-id');
      expect(account.status, AccountStatus.suspended);

      expect(await state.liftSuspension(account), isNull);
      account = state.accounts.firstWhere((item) => item.id == 'user-id');
      expect(account.status, AccountStatus.active);

      expect(await state.rerunVerification(account), isNull);
      account = state.accounts.firstWhere((item) => item.id == 'user-id');
      expect(account.verification, VerificationState.pending);
      expect(await state.sendPasswordReset(account), isNull);
      expect(
        backend.actions,
        containsAll([
          'change_role',
          'suspend',
          'lift_suspension',
          'request_reverification',
          'send_password_reset',
        ]),
      );
      state.dispose();
      await backend.close();
    });

    test('sign out clears production account data', () async {
      final backend = _FakeUserBackend();
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);

      await state.applyBackendProfile(null);

      expect(state.accounts, isEmpty);
      state.dispose();
      await backend.close();
    });
  });

  test('BackendAccount parses typed dates and unavailable metrics', () {
    final account = BackendAccount.fromJson({
      'id': 'u1',
      'email': 'person@example.com',
      'full_name': 'Person',
      'role': 'student',
      'unit': 'BSIT',
      'campus_id': '2026-1',
      'verification_status': 'verified',
      'account_status': 'active',
      'created_at': '2026-08-01T00:00:00Z',
      'last_sign_in_at': '2026-08-08T01:00:00Z',
      'invitation_sent_at': null,
      'email_confirmed_at': '2026-08-01T00:00:00Z',
      'suspension_reason': null,
      'suspended_until': null,
      'is_self': false,
      'activity_metrics_available': false,
    });

    expect(account.createdAt, isA<DateTime>());
    expect(account.lastSignInAt, isA<DateTime>());
    expect(account.activityMetricsAvailable, isFalse);
  });

  testWidgets('creating an administrator shows credentials to save or share', (
    tester,
  ) async {
    final backend = _FakeUserBackend();
    final state = AppState(useDemoData: false)..configureBackend(backend);
    await state.applyBackendProfile(_adminProfile);
    addTearDown(() async {
      state.dispose();
      await backend.close();
    });

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showInviteDialog(context, state),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'name@csu.edu.ph',
      ),
      'created.admin@csu.edu.ph',
    );
    final createButton = find.byWidgetPredicate(
      (widget) => widget is SrButton && widget.label == 'Create administrator',
    );
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(find.text('Administrator created'), findsOneWidget);
    expect(find.text('Save credentials file'), findsOneWidget);
    expect(find.text('Share credentials'), findsOneWidget);
    expect(find.text('TempPassword!2026'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
}

const _adminProfile = SessionProfile(
  id: 'admin-id',
  email: 'admin@csu.edu.ph',
  fullName: 'Internal Admin',
  role: 'internal_admin',
  campusClaim: null,
  campusId: null,
  unit: 'Registrar',
  verificationStatus: 'verified',
  onboardingComplete: true,
  accountStatus: 'active',
  createdAt: null,
);

class _FakeUserBackend implements SmartReserveBackend {
  final _accountsController =
      StreamController<List<BackendAccount>>.broadcast();
  final actions = <String>[];
  String? inviteFailure;
  var rows = <BackendAccount>[
    _account(
      id: 'admin-id',
      email: 'admin@csu.edu.ph',
      name: 'Internal Admin',
      role: 'internal_admin',
      isSelf: true,
    ),
    _account(
      id: 'user-id',
      email: 'student@csu.edu.ph',
      name: 'Live Student',
      role: 'student',
    ),
  ];

  Future<void> close() => _accountsController.close();

  @override
  Future<List<BackendAccount>> accounts() async => [...rows];

  @override
  Stream<List<BackendAccount>> accountStream() => _accountsController.stream;

  @override
  Future<BackendAccount> inviteAccountAdmin({
    required String email,
    required String role,
    String? note,
  }) async {
    actions.add('invite');
    if (inviteFailure case final message?) throw StateError(message);
    final row = _account(
      id: 'invited-id',
      email: email,
      name: email,
      role: role,
      status: 'invited',
    );
    rows = [row, ...rows];
    return row;
  }

  @override
  Future<BackendCreatedAdministrator> createAdministrator({
    required String email,
    required String role,
    String? note,
  }) async {
    actions.add('create_admin');
    final row = _account(
      id: 'created-admin-id',
      email: email,
      name: email,
      role: role,
    );
    rows = [row, ...rows];
    return BackendCreatedAdministrator(
      account: row,
      temporaryPassword: 'TempPassword!2026',
    );
  }

  @override
  Future<BackendAccount> changeAccountRole({
    required String accountId,
    required String role,
    required String reason,
  }) async => _replace(accountId, action: 'change_role', role: role);

  @override
  Future<BackendAccount> suspendUserAccount({
    required String accountId,
    required String reason,
    DateTime? suspendedUntil,
  }) async => _replace(
    accountId,
    action: 'suspend',
    status: 'suspended',
    suspensionReason: reason,
  );

  @override
  Future<BackendAccount> liftUserSuspension(String accountId) async =>
      _replace(accountId, action: 'lift_suspension', status: 'active');

  @override
  Future<BackendAccount> requestAccountReverification(String accountId) async =>
      _replace(
        accountId,
        action: 'request_reverification',
        verification: 'pending',
      );

  @override
  Future<BackendAccount> sendAccountPasswordReset(String accountId) async =>
      _replace(accountId, action: 'send_password_reset');

  @override
  Future<BackendAccount> resendAdminInvite(String accountId) async =>
      _replace(accountId, action: 'resend_invite');

  @override
  Future<String> revokeAdminInvite(String accountId) async {
    actions.add('revoke_invite');
    rows = rows.where((row) => row.id != accountId).toList();
    return accountId;
  }

  BackendAccount _replace(
    String id, {
    required String action,
    String? role,
    String? status,
    String? verification,
    String? suspensionReason,
  }) {
    actions.add(action);
    final old = rows.firstWhere((row) => row.id == id);
    final updated = _account(
      id: old.id,
      email: old.email,
      name: old.fullName,
      role: role ?? old.role,
      status: status ?? old.accountStatus,
      verification: verification ?? old.verificationStatus,
      suspensionReason: suspensionReason,
    );
    rows = [
      for (final row in rows)
        if (row.id == id) updated else row,
    ];
    return updated;
  }

  @override
  Future<List<BackendFacility>> facilities() async => [];

  @override
  Stream<List<BackendFacility>> facilityStream() => const Stream.empty();

  @override
  Future<List<BackendVerification>> verifications() async => [];

  @override
  Stream<List<BackendVerification>> verificationStream() =>
      const Stream.empty();

  @override
  Future<List<BackendReservation>> reservations() async => [];

  @override
  Stream<List<BackendReservation>> reservationStream() => const Stream.empty();

  @override
  Future<List<BackendNotification>> notifications() async => [];

  @override
  Stream<List<BackendNotification>> notificationStream() =>
      const Stream.empty();

  @override
  Future<Map<String, bool>> notificationPreferences() async => const {
    'Decision on my requests': true,
    'Reminder the day before': true,
    'New facilities on campus': false,
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BackendAccount _account({
  required String id,
  required String email,
  required String name,
  required String role,
  String status = 'active',
  String verification = 'verified',
  String? suspensionReason,
  bool isSelf = false,
}) => BackendAccount(
  id: id,
  email: email,
  fullName: name,
  role: role,
  unit: 'Campus unit',
  campusId: 'ID-1',
  verificationStatus: verification,
  accountStatus: status,
  createdAt: DateTime(2026, 8, 1),
  lastSignInAt: DateTime(2026, 8, 8),
  invitationSentAt: status == 'invited' ? DateTime(2026, 8, 8) : null,
  emailConfirmedAt: status == 'invited' ? null : DateTime(2026, 8, 1),
  suspensionReason: suspensionReason,
  suspendedUntil: null,
  isSelf: isSelf,
  activityMetricsAvailable: false,
);
