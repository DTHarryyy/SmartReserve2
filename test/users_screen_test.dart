import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_shell.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mobile uses a FAB, aligned search and filter controls, and a filter sheet',
    (tester) async {
      await _setViewport(tester, const Size(390, 844));
      final state = await _usersState();
      await tester.pumpWidget(_app(state));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('invite-admin-fab')), findsOneWidget);
      expect(find.text('＋ Invite administrator'), findsNothing);

      final search = tester.getRect(find.byKey(const Key('users-search')));
      final filters = tester.getRect(
        find.byKey(const Key('users-filter-button')),
      );
      expect(search.left, lessThan(filters.left));
      expect(search.top, filters.top);
      expect(search.bottom, filters.bottom);
      expect(search.height, 44);
      expect(filters.height, 44);
      expect(find.text('Filters'), findsOneWidget);
      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
      final role = tester.getSize(find.byKey(const Key('users-role-filter')));
      final status = tester.getSize(
        find.byKey(const Key('users-status-filter')),
      );
      expect(role.width, closeTo(status.width, 0.1));
      expect(find.text('Filter users'), findsOneWidget);
      expect(tester.takeException(), isNull);
      state.dispose();
    },
  );

  testWidgets('desktop keeps the inline invite action and no FAB', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1440, 900));
    final state = await _usersState();
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-admin-fab')), findsNothing);
    expect(find.text('＋ Invite administrator'), findsOneWidget);
    expect(tester.takeException(), isNull);
    state.dispose();
  });

  testWidgets('search, role, and status filters combine on mobile', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    final state = await _usersState();
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('users-search')),
        matching: find.byType(TextField),
      ),
      'bianca',
    );
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('users-role-filter')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('User').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('users-status-filter')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suspended').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show users'));
    await tester.pumpAndSettle();

    expect(find.text('Bianca Lorenzo'), findsOneWidget);
    expect(find.text('Jomar Padilla'), findsNothing);
    expect(find.text('1 of ${state.accounts.length}'), findsOneWidget);
    expect(tester.takeException(), isNull);
    state.dispose();
  });

  testWidgets('mobile account details open as a page with paired actions', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    final state = await _usersState();
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();

    final account = find.byKey(
      ValueKey('user-compact-${state.accounts.first.id}'),
    );
    await tester.ensureVisible(account);
    await tester.tap(account);
    await tester.pumpAndSettle();

    expect(find.text('Account details'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Close'), findsNothing);
    expect(find.text('Request re-verification'), findsNothing);
    final role = tester.getRect(find.text('Change role'));
    final suspend = tester.getRect(find.text('Suspend account'));
    expect(role.top, suspend.top);
    expect(tester.takeException(), isNull);
    state.dispose();
  });

  testWidgets('external admin receives restricted operations and clients UI', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1440, 900));
    final state = AppState();
    await state.applyBackendProfile(
      const SessionProfile(
        id: 'external-id',
        email: 'external@csu.edu.ph',
        fullName: 'External Admin',
        role: 'external_admin',
        campusClaim: null,
        campusId: null,
        unit: 'Business Affairs',
        verificationStatus: 'none',
        onboardingComplete: true,
        accountStatus: 'active',
        createdAt: null,
      ),
    );
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();

    expect(find.text('＋ New facility'), findsNothing);
    expect(find.text('Verifications'), findsNothing);
    expect(find.text('Audit log'), findsNothing);
    expect(find.text('Clients'), findsOneWidget);
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    expect(find.text('Accounts'), findsNothing);
    expect(find.text('＋ Invite administrator'), findsNothing);
    expect(find.textContaining('Campus verification'), findsOneWidget);
    state.dispose();
  });
}

Future<AppState> _usersState() async {
  final state = AppState();
  await state.applyBackendProfile(
    const SessionProfile(
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
    ),
  );
  state.goTo(AppView.users);
  return state;
}

Widget _app(AppState state) => AppScope(
  state: state,
  child: const MaterialApp(home: AppShell()),
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
