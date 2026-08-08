import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_shell.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile uses a FAB, full-width search, and one filter row', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    final state = await _usersState();
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-admin-fab')), findsOneWidget);
    expect(find.text('＋ Invite administrator'), findsNothing);

    final search = tester.getSize(find.byKey(const Key('users-search')));
    expect(search.width, closeTo(362, 1));
    final role = tester.getRect(find.byKey(const Key('users-role-filter')));
    final status = tester.getRect(find.byKey(const Key('users-status-filter')));
    expect(role.top, status.top);
    expect(role.width, closeTo(status.width, 0.1));
    expect(tester.takeException(), isNull);
    state.dispose();
  });

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
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('users-role-filter')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Student').last);
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

    expect(find.text('Bianca Lorenzo'), findsOneWidget);
    expect(find.text('Jomar Padilla'), findsNothing);
    expect(find.text('1 of ${state.accounts.length}'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
