import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/reports/reports_data.dart';

void main() {
  test(
    'latest report request wins when responses arrive out of order',
    () async {
      final backend = _ReportBackend();
      final state = _state(backend);
      addTearDown(state.dispose);
      final first = ReportScope.forRange(
        ReportRange.month,
        now: DateTime(2026, 8, 13, 10),
      );
      final second = ReportScope.forRange(
        ReportRange.month,
        category: 'Classroom',
        now: DateTime(2026, 8, 13, 10),
      );

      final firstRefresh = state.refreshReports(scope: first);
      final secondRefresh = state.refreshReports(scope: second);
      backend.calls[1].complete(_snapshot(second, .2));
      await secondRefresh;
      backend.calls[0].complete(_snapshot(first, .1));
      await firstRefresh;

      expect(state.reportSnapshot?.scope.category, 'Classroom');
      expect(state.reportSnapshot?.fraction, .2);
      expect(state.reportsLoading, isFalse);
    },
  );

  test(
    'same selection retains stale data but changed filters clear it',
    () async {
      final backend = _ReportBackend();
      final state = _state(backend);
      addTearDown(state.dispose);
      final initial = ReportScope.forRange(
        ReportRange.month,
        now: DateTime(2026, 8, 13, 10),
      );

      final loaded = state.refreshReports(scope: initial);
      backend.calls.single.complete(_snapshot(initial, .1));
      await loaded;

      final retry = state.refreshReports(
        scope: ReportScope.forRange(
          ReportRange.month,
          now: DateTime(2026, 8, 13, 11),
        ),
      );
      backend.calls[1].completeError(Exception('network connection failed'));
      await retry;
      expect(state.reportSnapshot, isNotNull);
      expect(state.reportsStale, isTrue);
      expect(state.reportsError, contains('connect'));

      final changed = state.refreshReports(
        scope: ReportScope.forRange(
          ReportRange.month,
          category: 'Auditorium',
          now: DateTime(2026, 8, 13, 11),
        ),
      );
      expect(state.reportSnapshot, isNull);
      backend.calls[2].completeError(Exception('network connection failed'));
      await changed;
      expect(state.reportsStale, isFalse);
    },
  );
}

AppState _state(_ReportBackend backend) {
  final state = AppState(useDemoData: false)..configureBackend(backend);
  state.sessionProfile = const SessionProfile(
    id: 'admin',
    email: 'admin@example.com',
    fullName: 'Admin',
    role: 'internal_admin',
    campusClaim: null,
    campusId: null,
    unit: null,
    verificationStatus: 'verified',
    onboardingComplete: true,
    accountStatus: 'active',
    createdAt: null,
  );
  return state;
}

class _ReportBackend implements SmartReserveBackend {
  final calls = <Completer<ReportSnapshot>>[];

  @override
  Future<ReportSnapshot> adminReport(ReportScope scope) {
    final call = Completer<ReportSnapshot>();
    calls.add(call);
    return call.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ReportSnapshot _snapshot(ReportScope scope, double fraction) => ReportSnapshot(
  scope: scope,
  generatedAt: scope.to,
  bookedHours: fraction * 100,
  availableHours: 100,
  fraction: fraction,
  utilisation: const [],
  bookedOccurrences: const [],
  demand: [
    for (var day = 1; day <= 7; day++)
      for (var hour = 7; hour <= 19; hour += 2)
        ReportDemandCell(day: day, hour: hour, count: 0),
  ],
  performance: const ReportPerformance(
    expired: 0,
    declined: 0,
    overCapacity: 0,
    perAdmin: [],
  ),
);
