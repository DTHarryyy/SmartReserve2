import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/reservations/reservations_screen.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/queue_shell.dart';

Future<void> _pumpReservations(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
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
        home: const Scaffold(body: ReservationsScreen()),
      ),
    ),
  );
}

void main() {
  testWidgets('reservation status filters are horizontally scrollable chips', (
    tester,
  ) async {
    final state = AppState()..requests = [];

    await _pumpReservations(tester, state);

    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('reservation-filter-scroll')),
    );
    expect(scroll.scrollDirection, Axis.horizontal);
    expect(find.byType(ChoiceChip), findsNWidgets(7));
    expect(
      find.byKey(const ValueKey('reservation-filter-completed')),
      findsOneWidget,
    );
    expect(find.text('Nothing selected'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reservation details stay hidden until a row is clicked', (
    tester,
  ) async {
    final state = AppState();
    final request = state.visibleRequests.first;

    await _pumpReservations(tester, state);

    var shell = tester.widget<QueueShell>(find.byType(QueueShell));
    expect(state.selectedRequest, isNull);
    expect(shell.panel, isNull);
    expect(shell.stacked, isTrue);

    await tester.tap(find.text(request.requester).first);
    await tester.pump();

    shell = tester.widget<QueueShell>(find.byType(QueueShell));
    expect(state.selectedRequestId, request.id);
    expect(shell.panel, isNotNull);
    expect(shell.stacked, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a completed reservation offers the post-use assessment', (
    tester,
  ) async {
    final state = AppState()..setRequestTab(RequestStatus.completed);
    final request = state.visibleRequests.firstWhere(
      (r) => r.lifecycleStatus == ReservationLifecycleStatus.completed,
    );

    await _pumpReservations(tester, state);
    await tester.tap(find.text(request.requester).first);
    await tester.pump();

    expect(state.selectedRequestId, request.id);
    expect(
      find.text('Post-use assessment', skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('isUrgentRequest', () {
    final now = DateTime(2026, 9, 27, 10);

    test('a pending request starting within 48 hours is urgent', () {
      expect(
        isUrgentRequest(
          status: RequestStatus.pending,
          startsAt: now.add(const Duration(hours: 20)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a request whose start has passed is never urgent', () {
      for (final status in RequestStatus.values) {
        expect(
          isUrgentRequest(
            status: status,
            startsAt: now.subtract(const Duration(days: 2)),
            now: now,
          ),
          isFalse,
          reason: status.name,
        );
      }
    });

    test('decided or far-off requests are not urgent', () {
      expect(
        isUrgentRequest(
          status: RequestStatus.approved,
          startsAt: now.add(const Duration(hours: 5)),
          now: now,
        ),
        isFalse,
      );
      expect(
        isUrgentRequest(
          status: RequestStatus.pending,
          startsAt: now.add(const Duration(days: 5)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
