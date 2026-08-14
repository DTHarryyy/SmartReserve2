import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/reports/reports_data.dart';

void main() {
  group('live report contract', () {
    final scope = ReportScope.forRange(
      ReportRange.month,
      category: 'Classroom',
      now: DateTime(2026, 8, 13, 12),
    );

    test('strictly parses a scoped live report', () {
      final snapshot = ReportSnapshot.fromJson(
        _payload(scope),
        expectedScope: scope,
      );

      expect(snapshot.fraction, .005);
      expect(snapshot.utilisation.single.facilityName, 'Room, "A"');
      expect(snapshot.bookedOccurrences.single.facilityId, 'f1');
      expect(snapshot.demand, hasLength(49));
      expect(formatUtilisationPercent(snapshot.fraction), '0.5%');
    });

    test('rejects a response for a different scope', () {
      final payload = _payload(scope)..['category'] = 'Auditorium';
      expect(
        () => ReportSnapshot.fromJson(payload, expectedScope: scope),
        throwsFormatException,
      );
    });

    test('rejects missing, negative, and incomplete metrics', () {
      final missing = _payload(scope)..remove('summary');
      final negative = _payload(scope);
      (negative['summary'] as Map<String, dynamic>)['booked_hours'] = -1;
      final incomplete = _payload(scope);
      (incomplete['demand'] as List).removeLast();

      expect(
        () => ReportSnapshot.fromJson(missing, expectedScope: scope),
        throwsFormatException,
      );
      expect(
        () => ReportSnapshot.fromJson(negative, expectedScope: scope),
        throwsFormatException,
      );
      expect(
        () => ReportSnapshot.fromJson(incomplete, expectedScope: scope),
        throwsFormatException,
      );
    });

    test('semester begins at Manila midnight on August 1', () {
      final semester = ReportScope.forRange(
        ReportRange.semester,
        now: DateTime(2026, 8, 13, 12),
      );
      expect(semester.from, DateTime.utc(2026, 7, 31, 16));
    });

    test('CSV uses verified values and escapes labels', () {
      final snapshot = ReportSnapshot.fromJson(
        _payload(scope),
        expectedScope: scope,
      );
      final csv = reportCsv(snapshot, exportedBy: 'Admin "One"');

      expect(csv, contains('"Room, ""A"""'));
      expect(csv, contains('1.00,200.00,0.50'));
      expect(csv, contains('"Admin ""One"""'));
      expect(csv, contains('2026-08-13T04:00:00.000Z'));
    });
  });
}

Map<String, dynamic> _payload(ReportScope scope) => {
  'from': scope.from.toIso8601String(),
  'to': scope.to.toIso8601String(),
  'category': scope.category,
  'generated_at': '2026-08-13T04:00:00Z',
  'summary': {'booked_hours': 1, 'available_hours': 200, 'fraction': .005},
  'utilisation': [
    {
      'facility_id': 'f1',
      'facility_name': 'Room, "A"',
      'building': 'Main',
      'category': 'Classroom',
      'booked_hours': 1,
      'available_hours': 200,
      'fraction': .005,
    },
  ],
  'booked_occurrences': [
    {
      'occurrence_id': 'o1',
      'request_id': 'r1',
      'facility_id': 'f1',
      'requester': 'Student',
      'purpose': 'Review',
      'request_status': 'approved',
      'starts_at': '2026-08-10T01:00:00Z',
      'ends_at': '2026-08-10T02:00:00Z',
      'booked_hours': 1,
    },
  ],
  'demand': [
    for (var day = 1; day <= 7; day++)
      for (var hour = 7; hour <= 19; hour += 2)
        {'day': day, 'hour': hour, 'count': 0},
  ],
  'performance': {
    'median_hours': null,
    'within_48': null,
    'expired': 0,
    'declined': 0,
    'over_capacity': 0,
    'per_admin': <Map<String, dynamic>>[],
  },
};
