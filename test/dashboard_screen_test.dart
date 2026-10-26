import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/dashboard/dashboard_screen.dart';
import 'package:smartreserve/theme/sr_theme.dart';

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
  accountAccessType: 'administrator',
  mustChangePassword: false,
  createdAt: null,
);

Future<void> _pump(WidgetTester tester, AppState state, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1280, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(
        theme: SrThemeData.light(),
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: Scaffold(body: DashboardScreen(onNewFacility: () {})),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('tiles show live counts and open their queue', (tester) async {
    final state = AppState()
      ..sessionProfile = _profile('internal_admin')
      ..view = AppView.dashboard;

    await _pump(tester, state);

    expect(
      find.descendant(
        of: find.byKey(const Key('dashboard-kpi-pending')),
        matching: find.text('${state.pendingRequests}'),
      ),
      findsOneWidget,
    );
    expect(find.text('Organizations'), findsOneWidget);
    expect(find.text('Loyalty'), findsNothing);

    await tester.tap(find.byKey(const Key('dashboard-kpi-pending')));
    await tester.pump();
    expect(state.view, AppView.reservations);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external admins get their own shortcuts', (tester) async {
    final state = AppState()
      ..sessionProfile = _profile('external_admin')
      ..view = AppView.dashboard;

    await _pump(tester, state);

    expect(find.text('Loyalty'), findsOneWidget);
    expect(find.text('Clients'), findsOneWidget);
    expect(find.text('Organizations'), findsNothing);
  });

  testWidgets('lays out on a phone without overflow', (tester) async {
    final state = AppState()
      ..sessionProfile = _profile('internal_admin')
      ..view = AppView.dashboard;

    await _pump(tester, state, size: const Size(390, 2400));

    expect(tester.takeException(), isNull);
    expect(find.text('Shortcuts'), findsOneWidget);
  });
}
