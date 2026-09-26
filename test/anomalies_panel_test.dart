import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/anomalies/anomalies_screen.dart';
import 'package:smartreserve/model/anomaly.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/queue_shell.dart';

ReservationAnomaly _anomaly() => ReservationAnomaly.fromJson({
  'id': 'anomaly-1',
  'renter_id': 'renter-1',
  'facility_id': 'facility-1',
  'rule_key': 'repeated_no_show',
  'severity': 'high',
  'status': 'open',
  'title': 'Repeated no-shows',
  'renter_name': 'Jamie Cruz',
  'facility_name': 'Main Gym',
});

Future<void> _pumpAnomalies(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1400, 900);
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
        home: const Scaffold(body: AnomaliesScreen()),
      ),
    ),
  );
}

void main() {
  testWidgets('anomaly details stay hidden until a row is clicked', (
    tester,
  ) async {
    final anomaly = _anomaly();
    final state = AppState()..anomalyRows = [anomaly];

    await _pumpAnomalies(tester, state);

    var shell = tester.widget<QueueShell>(find.byType(QueueShell));
    expect(state.selectedAnomalyId, isNull);
    expect(shell.panel, isNull);
    expect(shell.stacked, isTrue);

    await tester.tap(find.byKey(const ValueKey('anomaly-row-anomaly-1')));
    await tester.pump();

    shell = tester.widget<QueueShell>(find.byType(QueueShell));
    expect(state.selectedAnomalyId, anomaly.id);
    expect(shell.panel, isNotNull);
    expect(shell.stacked, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('changing anomaly filters closes the selected detail', () {
    final state = AppState()
      ..anomalyRows = [_anomaly()]
      ..selectedAnomalyId = 'anomaly-1';

    state.setAnomalyFilters(const AnomalyFilters(statuses: ['resolved']));

    expect(state.selectedAnomalyId, isNull);
    expect(state.selectedAnomalyDetail, isNull);
    expect(state.anomalyFilters.statuses, ['resolved']);
  });
}
