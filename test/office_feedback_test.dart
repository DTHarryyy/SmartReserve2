import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/feedback/office_feedback_dialog.dart';
import 'package:smartreserve/features/feedback/office_feedback_panel.dart';
import 'package:smartreserve/model/feedback.dart';
import 'package:smartreserve/theme/sr_theme.dart';

OfficeFeedback _entry(
  String id,
  int overall, {
  int? responsiveness,
  String comment = '',
}) => OfficeFeedback(
  id: id,
  userId: 'renter-$id',
  overallRating: overall,
  responsivenessRating: responsiveness,
  comment: comment,
  createdAt: DateTime.utc(2026, 10, 20, 2),
  personName: 'Renter $id',
);

class _Backend implements SmartReserveBackend {
  List<OfficeFeedback> rows = [];
  final submitted = <Map<String, Object?>>[];

  @override
  Future<List<OfficeFeedback>> officeFeedback() async => rows;

  @override
  Future<void> submitOfficeFeedback({
    required int overall,
    int? responsiveness,
    int? helpfulness,
    int? clarity,
    String comment = '',
  }) async {
    submitted.add({
      'overall': overall,
      'responsiveness': responsiveness,
      'comment': comment,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

class _State extends AppState {
  _State() : super(useDemoData: false);

  @override
  bool get hasSession => true;
}

Future<void> _pump(WidgetTester tester, AppState state, Widget home) async {
  tester.view.physicalSize = const Size(1280, 1200);
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
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('the summary averages only the dimensions people rated', () {
    final summary = OfficeFeedbackSummary.of([
      _entry('a', 5, responsiveness: 4),
      _entry('b', 2),
      _entry('c', 1, responsiveness: 2),
    ]);
    expect(summary.count, 3);
    expect(summary.overall, closeTo(8 / 3, 1e-9));
    expect(summary.responsiveness, 3);
    expect(summary.helpfulness, isNull);
    expect(summary.lowCount, 2);
  });

  testWidgets('a renter rates the office', (tester) async {
    final backend = _Backend();
    final state = _State()..backend = backend;

    await _pump(
      tester,
      state,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOfficeFeedbackDialog(context, state: state),
            child: const Text('Rate'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Rate'));
    await tester.pumpAndSettle();

    final submit = find.byKey(const Key('office-feedback-submit'));
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.tap(find.bySemanticsLabel('4 of 5 stars'));
    await tester.tap(find.bySemanticsLabel('Response time 5 of 5'));
    await tester.enterText(
      find.byKey(const Key('office-feedback-comment')),
      'Quick approval.',
    );
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(backend.submitted.single, {
      'overall': 4,
      'responsiveness': 5,
      'comment': 'Quick approval.',
    });
    expect(find.text('Rate our office'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('admins see office ratings in their own Feedback tab', (
    tester,
  ) async {
    final backend = _Backend()
      ..rows = [_entry('a', 5, comment: 'Very helpful staff'), _entry('b', 1)];
    final state = _State()..backend = backend;
    await state.refreshOfficeFeedback();

    await _pump(tester, state, const Scaffold(body: OfficeFeedbackPanel()));

    expect(find.text('Very helpful staff'), findsOneWidget);
    expect(find.text('3.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('office-feedback-b')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
