import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:smartreserve/features/add_facility/facility_editor_focus.dart';
import 'package:smartreserve/features/reports/reports_data.dart';
import 'package:smartreserve/model/facility.dart';

void main() {
  final scope = ReportScope(
    range: ReportRange.month,
    from: DateTime.parse('2030-01-01T00:00:00Z'),
    to: DateTime.parse('2030-01-02T00:00:00Z'),
    category: 'Report Test',
  );

  Map<String, dynamic> validPayload() => {
    'contract_version': 3,
    'from': scope.from.toUtc().toIso8601String(),
    'to': scope.to.toUtc().toIso8601String(),
    'category': scope.category,
    'generated_at': '2030-01-02T00:05:00Z',
    'summary': {'booked_hours': 2, 'available_hours': 10, 'fraction': .2},
    'utilisation': [
      {
        'facility_id': 'facility-1',
        'facility_name': 'Report Room',
        'building': 'Test Building',
        'category': 'Report Test',
        'booked_hours': 2,
        'available_hours': 10,
        'fraction': .2,
      },
    ],
    'booked_occurrences': [
      {
        'occurrence_id': 'occurrence-1',
        'request_id': 'request-1',
        'facility_id': 'facility-1',
        'requester': 'Test Requester',
        'purpose': 'Booked test',
        'request_status': 'approved',
        'starts_at': '2030-01-01T01:00:00Z',
        'ends_at': '2030-01-01T03:00:00Z',
        'booked_hours': 2,
      },
    ],
    'demand': [
      for (var day = 1; day <= 7; day++)
        for (final hour in const [7, 9, 11, 13, 15, 17, 19])
          {'day': day, 'hour': hour, 'count': 0},
    ],
    'performance': {
      'median_hours': 1.5,
      'within_48': .9,
      'expired': 0,
      'declined': 1,
      'over_capacity': 0,
      'per_admin': [
        {
          'admin_id': null,
          'name': 'Unattributed',
          'decisions': 1,
          'median_hours': 1.5,
        },
      ],
    },
    'revenue': {
      'gross_verified_centavos': 250000,
      'refunds_centavos': 50000,
      'net_revenue_centavos': 200000,
      'outstanding_centavos': 75000,
      'verified_payment_count': 2,
      'paid_reservation_count': 1,
    },
    'monthly_statistics': [
      {
        'month_start': '2030-01-01T00:00:00+08:00',
        'submitted_reservations': 3,
        'confirmed_reservations': 2,
        'completed_occurrences': 1,
        'booked_hours': 2,
        'utilisation_fraction': .2,
        'gross_verified_centavos': 250000,
        'refunds_centavos': 50000,
        'net_revenue_centavos': 200000,
      },
    ],
  };

  ReportContractFailureCode parseFailure(Map<String, dynamic> payload) {
    try {
      ReportSnapshot.fromJson(payload, expectedScope: scope);
    } on ReportContractException catch (error) {
      return error.code;
    }
    fail('Expected a report contract failure.');
  }

  test('parses a valid contract-version-3 payload with revenue', () {
    final snapshot = ReportSnapshot.fromJson(
      validPayload(),
      expectedScope: scope,
    );

    expect(snapshot.bookedHours, 2);
    expect(snapshot.availableHours, 10);
    expect(snapshot.demand, hasLength(49));
    expect(snapshot.revenue.netRevenueCentavos, 200000);
    expect(snapshot.monthlyStatistics.single.completedOccurrences, 1);
  });

  test('rejects an unsupported contract version', () {
    final payload = validPayload()..['contract_version'] = 1;

    expect(parseFailure(payload), ReportContractFailureCode.unsupportedVersion);
  });

  test('rejects a missing contract version as unsupported', () {
    final payload = validPayload()..remove('contract_version');

    expect(parseFailure(payload), ReportContractFailureCode.unsupportedVersion);
  });

  test('rejects a scope mismatch', () {
    final payload = validPayload()..['category'] = 'Other';

    expect(parseFailure(payload), ReportContractFailureCode.scopeMismatch);
  });

  test('rejects an orphan booked occurrence', () {
    final payload = validPayload();
    (payload['booked_occurrences'] as List).first['facility_id'] = 'missing';

    expect(
      parseFailure(payload),
      ReportContractFailureCode.unreconciledFacility,
    );
  });

  test('rejects an incomplete demand grid', () {
    final payload = validPayload();
    (payload['demand'] as List).removeLast();

    expect(
      parseFailure(payload),
      ReportContractFailureCode.incompleteDemandGrid,
    );
  });

  test('rejects a duplicate demand cell', () {
    final payload = validPayload();
    (payload['demand'] as List).last = {'day': 1, 'hour': 7, 'count': 0};

    expect(
      parseFailure(payload),
      ReportContractFailureCode.incompleteDemandGrid,
    );
  });

  test('rejects an invalid utilisation fraction', () {
    final payload = validPayload();
    (payload['utilisation'] as List).first['fraction'] = .7;

    expect(parseFailure(payload), ReportContractFailureCode.unreconciledTotals);
  });

  test('rejects summary and occurrence reconciliation failures', () {
    final payload = validPayload();
    (payload['summary'] as Map)['booked_hours'] = 3;

    expect(parseFailure(payload), ReportContractFailureCode.unreconciledTotals);
  });

  group('quality issue rules', () {
    test('does not flag verified accurate pins by centroid distance alone', () {
      final issues = qualityIssuesFor([
        _facility(
          name: 'Far But Verified',
          coords: const LatLng(18.352772, 121.649970),
          pinConfidence: PinConfidence.verified,
          accuracy: 4,
        ),
      ]);

      expect(issues, isEmpty);
    });

    test('flags an existing unverified pin for review', () {
      final issues = qualityIssuesFor([
        _facility(
          name: 'Review Pin',
          coords: const LatLng(18.351092, 121.649970),
          pinConfidence: PinConfidence.needsCheck,
          accuracy: 4,
        ),
      ]);

      expect(issues, hasLength(1));
      expect(issues.single.type, QualityIssueType.unverifiedPin);
      expect(issues.single.severity, QualitySeverity.warning);
      expect(issues.single.focus, FacilityEditorFocus.location);
      expect(issues.single.actionLabel, 'Review pin');
    });

    test('keeps trusted location and photo issue behavior', () {
      final issues = qualityIssuesFor([
        _facility(
          name: 'Missing Pin',
          coords: null,
          pinConfidence: PinConfidence.none,
          accuracy: null,
        ),
        _facility(
          name: 'Outside Pin',
          coords: const LatLng(18.360000, 121.649970),
          pinConfidence: PinConfidence.needsCheck,
          accuracy: 4,
        ),
        _facility(
          name: 'Coarse Pin',
          coords: const LatLng(18.351092, 121.649970),
          pinConfidence: PinConfidence.verified,
          accuracy: 30,
        ),
        _facility(
          name: 'No Photos',
          coords: const LatLng(18.351092, 121.649970),
          pinConfidence: PinConfidence.verified,
          accuracy: 4,
          photoCount: 0,
        ),
      ]);

      expect(issues.map((issue) => issue.type).toList(), [
        QualityIssueType.missingPin,
        QualityIssueType.pinOutsideCampus,
        QualityIssueType.lowCoordinateAccuracy,
        QualityIssueType.missingPhotos,
      ]);
      expect(issues.map((issue) => issue.actionLabel).toList(), [
        'Add pin',
        'Correct pin',
        'Improve precision',
        'Add photos',
      ]);
    });
  });
}

Facility _facility({
  required String name,
  required LatLng? coords,
  required PinConfidence pinConfidence,
  required int? accuracy,
  int photoCount = 3,
}) => Facility(
  id: name.toLowerCase().replaceAll(' ', '-'),
  name: name,
  room: 'T-101',
  building: 'College of Information and Computing Sciences',
  category: 'Classroom',
  capacity: 30,
  pinConfidence: pinConfidence,
  state: FacilityState.active,
  floor: 'Ground floor',
  coords: coords,
  accuracy: accuracy,
  description: 'Test facility',
  amenities: const [],
  hours: '07:00-19:00',
  days: 'Mon-Fri',
  approvalRequired: true,
  maxDuration: '4 hours',
  advance: '30 days ahead',
  updated: 'Test',
  bookings: 0,
  photoCount: photoCount,
);
