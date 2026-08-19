import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/users/invite_dialog.dart';
import 'package:smartreserve/features/users/user_detail_dialog.dart';
import 'package:smartreserve/model/account.dart';
import 'package:smartreserve/model/notice.dart';
import 'package:smartreserve/widgets/sr_controls.dart';
import 'package:smartreserve/widgets/toast_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        ..failures['invite'] = const AccountManagementException(
          code: 'server_error',
          message: 'Internal email provider detail',
          status: 500,
          requestId: 'request-123',
        );
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);
      final before = state.accounts.length;

      final error = await state.inviteAdmin(
        'failed.admin@csu.edu.ph',
        AccountRole.externalAdmin,
        '',
      );

      expect(error, contains('support reference request-123'));
      expect(state.accounts, hasLength(before));
      expect(state.toast?.text, 'Invitation wasn’t sent.');
      expect(state.toast?.tone, AdvisoryTone.block);
      state.dispose();
      await backend.close();
    });

    test('persisted account actions replace the authoritative row', () async {
      final backend = _FakeUserBackend();
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);
      var account = state.accounts.last;

      expect(
        await state.changeRole(account, AccountRole.externalAdmin),
        isNull,
      );
      account = state.accounts.firstWhere((item) => item.id == 'user-id');
      expect(account.role, AccountRole.externalAdmin);

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

    test(
      'failed account actions keep account and audit state unchanged',
      () async {
        const failure = AccountManagementException(
          code: 'forbidden',
          message: 'Only an active internal administrator can manage users.',
          status: 403,
        );
        final backend = _FakeUserBackend();
        for (final action in const [
          'change_role',
          'suspend',
          'lift_suspension',
          'request_reverification',
          'send_password_reset',
          'resend_invite',
          'revoke_invite',
          'create_admin',
          'invite',
        ]) {
          backend.failures[action] = failure;
        }
        final state = AppState(useDemoData: false)..configureBackend(backend);
        await state.applyBackendProfile(_adminProfile);
        final account = state.accounts.last;
        final auditCount = state.audit.length;

        expect(
          await state.changeRole(account, AccountRole.externalAdmin),
          contains('permission'),
        );
        expect(
          await state.suspendAccount(account, 'Repeated no-shows', null),
          contains('permission'),
        );
        expect(await state.liftSuspension(account), contains('permission'));
        expect(await state.rerunVerification(account), contains('permission'));
        expect(await state.sendPasswordReset(account), contains('permission'));
        expect(await state.resendInvite(account), contains('permission'));
        expect(await state.revokeInvite(account), contains('permission'));
        expect(
          (await state.createAdministrator(
            'created@csu.edu.ph',
            AccountRole.internalAdmin,
            '',
          )).error,
          contains('permission'),
        );
        expect(
          await state.inviteAdmin(
            'invited@csu.edu.ph',
            AccountRole.externalAdmin,
            '',
          ),
          contains('permission'),
        );

        expect(state.accounts, hasLength(2));
        expect(account.role, AccountRole.user);
        expect(account.status, AccountStatus.active);
        expect(account.verification, VerificationState.verified);
        expect(state.audit, hasLength(auditCount));
        expect(state.toast?.tone, AdvisoryTone.block);
        state.dispose();
        await backend.close();
      },
    );

    test(
      'local account validation stays inline without an error toast',
      () async {
        final backend = _FakeUserBackend();
        final state = AppState(useDemoData: false)..configureBackend(backend);
        await state.applyBackendProfile(_adminProfile);
        final account = state.accounts.last;

        expect(
          await state.changeRole(account, account.role),
          'Choose a different role.',
        );
        expect(state.toast, isNull);
        expect(backend.actions, isNot(contains('change_role')));
        state.dispose();
        await backend.close();
      },
    );

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
      'role': 'user',
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

  test('backend account payloads collapse known legacy roles to user', () {
    for (final legacy in ['student', 'faculty', 'staff', 'guest']) {
      expect(
        BackendAccount.fromJson({'id': 'u1', 'role': legacy}).role,
        'user',
      );
    }
  });

  test('backend account payloads reject unknown roles', () {
    expect(
      () => BackendAccount.fromJson({'id': 'u1', 'role': 'super_admin'}),
      throwsFormatException,
    );
  });

  test('account management exceptions preserve structured function errors', () {
    final error = AccountManagementException.fromFunctionException(
      const FunctionsHttpException(
        status: 409,
        details: {
          'code': 'guardrail',
          'error': 'The last active internal administrator cannot be demoted.',
          'request_id': 'request-409',
        },
      ),
    );

    expect(error.code, 'guardrail');
    expect(error.status, 409);
    expect(error.requestId, 'request-409');
    expect(error.message, contains('cannot be demoted'));
  });

  test('account management exceptions classify transport and JSON errors', () {
    final network = AccountManagementException.fromFunctionException(
      const FunctionsFetchException(details: 'SocketException'),
    );
    final server = AccountManagementException.fromFunctionException(
      const FunctionsHttpException(
        status: 500,
        details:
            '{"code":"server_error","error":"Try again.","request_id":"request-500"}',
      ),
    );

    expect(network.code, 'network');
    expect(network.isRetryable, isTrue);
    expect(server.code, 'server_error');
    expect(server.requestId, 'request-500');
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
      _actionApp(state, (context) => showInviteDialog(context, state)),
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

  testWidgets(
    'failed role change keeps the form and shows route-safe feedback',
    (tester) async {
      await _setViewport(tester, const Size(1200, 800));
      final backend = _FakeUserBackend()
        ..failures['change_role'] = const AccountManagementException(
          code: 'network',
          message: 'SocketException: private transport detail',
          status: 0,
        );
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);
      final account = state.accounts.last;
      addTearDown(() async {
        state.dispose();
        await backend.close();
      });

      await tester.pumpWidget(
        _actionApp(
          state,
          (context) => showUserDetail(context, state: state, account: account),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change role'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is DropdownButton<AccountRole>,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('External admin').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply role change'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('Check your connection'), findsOneWidget);
      expect(find.text('Role change wasn’t saved.'), findsOneWidget);
      expect(find.byKey(const Key('global-toast')), findsOneWidget);
      expect(find.text('Apply role change'), findsOneWidget);
      expect(account.role, AccountRole.user);
      await tester.pump(const Duration(seconds: 6));
    },
  );

  testWidgets('failed suspension stays visible on the mobile account page', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    final backend = _FakeUserBackend()
      ..failures['suspend'] = const AccountManagementException(
        code: 'forbidden',
        message: 'Only an active internal administrator can manage users.',
        status: 403,
      );
    final state = AppState(useDemoData: false)..configureBackend(backend);
    await state.applyBackendProfile(_adminProfile);
    final account = state.accounts.last;
    addTearDown(() async {
      state.dispose();
      await backend.close();
    });

    await tester.pumpWidget(
      _actionApp(
        state,
        (context) => showUserDetail(context, state: state, account: account),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Suspend account').first);
    await tester.tap(find.text('Suspend account').first);
    await tester.pumpAndSettle();
    await tester.enterText(_reasonField(), 'Repeated no-shows');
    await tester.ensureVisible(find.text('Suspend account').last);
    await tester.tap(find.text('Suspend account').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('no longer has permission'), findsOneWidget);
    expect(find.text('Suspension wasn’t saved.'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Repeated no-shows'), findsOneWidget);
    expect(account.status, AccountStatus.active);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('lift and invitation failures remain in account details', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1200, 800));
    final backend = _FakeUserBackend();
    backend.rows[1] = _account(
      id: 'user-id',
      email: 'student@csu.edu.ph',
      name: 'Live Student',
      role: 'user',
      status: 'suspended',
      suspensionReason: 'Repeated no-shows',
    );
    backend.failures['lift_suspension'] = const AccountManagementException(
      code: 'network',
      message: 'offline',
      status: 0,
    );
    final state = AppState(useDemoData: false)..configureBackend(backend);
    await state.applyBackendProfile(_adminProfile);
    var account = state.accounts.last;
    addTearDown(() async {
      state.dispose();
      await backend.close();
    });

    await tester.pumpWidget(
      _actionApp(
        state,
        (context) => showUserDetail(context, state: state, account: account),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lift suspension'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Suspension couldn’t be lifted.'), findsOneWidget);
    expect(find.textContaining('Check your connection'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    backend.rows[1] = _account(
      id: 'user-id',
      email: 'student@csu.edu.ph',
      name: 'Live Student',
      role: 'external_admin',
      status: 'invited',
    );
    await state.refreshAccounts();
    account = state.accounts.last;
    backend.failures['resend_invite'] = const AccountManagementException(
      code: 'invite_not_pending',
      message: 'This invitation is no longer pending.',
      status: 409,
    );
    backend.failures['revoke_invite'] = const AccountManagementException(
      code: 'invite_not_pending',
      message: 'This invitation is no longer pending.',
      status: 409,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resend invitation'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Invitation wasn’t resent.'), findsOneWidget);
    expect(find.text('This invitation is no longer pending.'), findsOneWidget);

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke').last);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Invitation wasn’t revoked.'), findsOneWidget);
    expect(find.text('This invitation is no longer pending.'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets(
    'administrator creation failure retains input and safe reference',
    (tester) async {
      final backend = _FakeUserBackend()
        ..failures['create_admin'] = const AccountManagementException(
          code: 'server_error',
          message: 'Database detail that must not be displayed',
          status: 500,
          requestId: 'create-reference',
        );
      final state = AppState(useDemoData: false)..configureBackend(backend);
      await state.applyBackendProfile(_adminProfile);
      addTearDown(() async {
        state.dispose();
        await backend.close();
      });

      await tester.pumpWidget(
        _actionApp(state, (context) => showInviteDialog(context, state)),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == 'name@csu.edu.ph',
        ),
        'failed.admin@csu.edu.ph',
      );
      await tester.ensureVisible(find.text('Create administrator'));
      await tester.tap(find.text('Create administrator'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Administrator wasn’t created.'), findsOneWidget);
      expect(
        find.textContaining('support reference create-reference'),
        findsOneWidget,
      );
      expect(find.textContaining('Database detail'), findsNothing);
      expect(find.text('failed.admin@csu.edu.ph'), findsOneWidget);
      expect(find.text('Create administrator'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    },
  );
}

Widget _actionApp(
  AppState state,
  Future<void> Function(BuildContext context) onOpen,
) => AppScope(
  state: state,
  child: MaterialApp(
    builder: (context, child) =>
        AppToastHost(child: child ?? const SizedBox.shrink()),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => onOpen(context),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);

Finder _reasonField() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.hintText?.contains('account holder') ?? false),
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
  final failures = <String, AccountManagementException>{};
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
      role: 'user',
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
    _throwIfFailed('invite');
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
    _throwIfFailed('create_admin');
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
    _throwIfFailed('revoke_invite');
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
    _throwIfFailed(action);
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

  void _throwIfFailed(String action) {
    final failure = failures[action];
    if (failure != null) throw failure;
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
