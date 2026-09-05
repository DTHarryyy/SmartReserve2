import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/reports/reports_data.dart';
import 'package:smartreserve/features/reports/reports_screen.dart';
import 'package:smartreserve/theme/sr_theme.dart';

Future<void> _pumpReports(
  WidgetTester tester,
  AppState state, {
  Size size = const Size(1200, 800),
  void Function(QualityIssue issue)? onResolveQualityIssue,
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
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: ReportsScreen(onResolveQualityIssue: onResolveQualityIssue),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('initial live load shows section skeletons', (tester) async {
    final state = AppState(useDemoData: false);

    await _pumpReports(tester, state);

    expect(find.text('Loading verified report data'), findsWidgets);
    expect(find.text('Data quality'), findsOneWidget);
  });

  testWidgets('demo reports render the rebuilt scope card and sections', (
    tester,
  ) async {
    final state = AppState();

    await _pumpReports(tester, state);

    expect(find.text('Reporting period'), findsOneWidget);
    expect(find.text('Facility category'), findsOneWidget);
    expect(find.text('Utilisation'), findsWidgets);
    expect(find.text('Demand'), findsWidgets);
    expect(find.text('Approval performance'), findsWidgets);
    expect(find.text('Data quality'), findsOneWidget);
  });

  testWidgets('failed state shows safe verification panel', (tester) async {
    final state = AppState(useDemoData: false)
      ..reportState = const ReportFailed(
        ReportFailure(
          explanation:
              'The report included data outside this report’s facility scope, so it was not shown.',
          supportReference: 'RPT-CONTRACT-FACILITY-SCOPE',
        ),
      );

    await _pumpReports(tester, state);

    expect(find.text('Report data could not be verified'), findsOneWidget);
    expect(find.textContaining('RPT-CONTRACT-FACILITY-SCOPE'), findsOneWidget);
    expect(find.text('Copy details'), findsOneWidget);
  });

  testWidgets('compact layout stacks scope controls', (tester) async {
    final state = AppState();

    await _pumpReports(tester, state, size: const Size(360, 760));

    expect(tester.takeException(), isNull);
    expect(find.text('Reporting period'), findsOneWidget);
    expect(find.text('Facility category'), findsOneWidget);
  });

  testWidgets('wide data quality renders responsive table headers', (
    tester,
  ) async {
    final state = AppState();

    await _pumpReports(tester, state, size: const Size(1600, 900));

    expect(tester.takeException(), isNull);
    expect(find.text('Facility'), findsOneWidget);
    expect(find.text('Issue'), findsOneWidget);
    expect(find.text('Why it matters'), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
  });

  testWidgets('compact data quality renders labeled issue cards', (
    tester,
  ) async {
    final state = AppState();

    await _pumpReports(tester, state, size: const Size(430, 820));

    expect(tester.takeException(), isNull);
    expect(find.text('Issue'), findsWidgets);
    expect(find.text('Why it matters'), findsWidgets);
  });

  testWidgets('quality actions pass the contextual issue', (tester) async {
    final state = AppState();
    Object? selectedIssue;

    await _pumpReports(
      tester,
      state,
      size: const Size(1200, 800),
      onResolveQualityIssue: (issue) => selectedIssue = issue,
    );
    await tester.tap(find.text('Review pin').first);
    await tester.pump();

    expect(selectedIssue, isNotNull);
  });
}
