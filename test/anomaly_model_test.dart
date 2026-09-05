import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/anomaly.dart';

void main() {
  group('AnomalySeverity', () {
    test('falls back to info for an unknown raw value', () {
      expect(AnomalySeverity.fromRaw('made_up'), AnomalySeverity.info);
      expect(AnomalySeverity.fromRaw('critical'), AnomalySeverity.critical);
    });
  });

  group('AnomalyStatus', () {
    test('falls back to open for an unknown raw value', () {
      expect(AnomalyStatus.fromRaw('made_up'), AnomalyStatus.open);
      expect(AnomalyStatus.fromRaw('false_positive'), AnomalyStatus.falsePositive);
    });
  });

  group('RiskLevel', () {
    test('falls back to normal for an unknown raw value', () {
      expect(RiskLevel.fromRaw('made_up'), RiskLevel.normal);
      expect(RiskLevel.fromRaw('critical'), RiskLevel.critical);
    });
  });

  group('AnomalyFilters', () {
    test('serializes to the RPC filter shape', () {
      const filters = AnomalyFilters(
        statuses: ['open'],
        severities: ['high'],
        rules: ['repeated_no_show'],
        includeObserve: true,
      );
      expect(filters.toJson(), {
        'statuses': ['open'],
        'severities': ['high'],
        'rules': ['repeated_no_show'],
        'include_observe': true,
      });
    });

    test('copyWith replaces only the given fields', () {
      const filters = AnomalyFilters();
      final updated = filters.copyWith(rules: ['abnormal_duration']);
      expect(updated.rules, ['abnormal_duration']);
      expect(updated.statuses, filters.statuses);
      expect(updated.includeObserve, filters.includeObserve);
    });
  });

  group('ReservationAnomaly.fromJson', () {
    Map<String, dynamic> row({String detectionMode = 'active'}) => {
      'id': 'anomaly-1',
      'renter_id': 'renter-1',
      'admin_lane': 'external',
      'facility_id': 'facility-1',
      'rule_key': 'repeated_no_show',
      'correlation_key': 'corr-1',
      'detection_mode': detectionMode,
      'severity': 'high',
      'status': 'open',
      'base_risk_points': 25,
      'effective_risk_points': 25,
      'title': 'Repeated no-shows',
      'explanation': 'Three no-shows in the last 30 days.',
      'evidence_summary': {'count': 3, 'window_days': 30},
      'window_started_at': '2026-07-30T00:00:00Z',
      'window_ended_at': '2026-08-29T00:00:00Z',
      'last_contributing_at': '2026-08-28T00:00:00Z',
      'last_detected_at': '2026-08-28T00:00:00Z',
      'last_evaluated_at': '2026-08-29T00:00:00Z',
      'renter_name': 'Jamie Cruz',
      'facility_name': 'Main Gym',
      'facility_building': 'Building A',
      'local_risk_score': 42,
      'local_risk_level': 'moderate',
    };

    test('parses a fully populated row', () {
      final anomaly = ReservationAnomaly.fromJson(row());
      expect(anomaly.id, 'anomaly-1');
      expect(anomaly.severity, AnomalySeverity.high);
      expect(anomaly.status, AnomalyStatus.open);
      expect(anomaly.effectiveRiskPoints, 25);
      expect(anomaly.evidenceSummary['count'], 3);
      expect(anomaly.localRiskLevel, RiskLevel.moderate);
      expect(anomaly.isObserve, isFalse);
    });

    test('observe-mode rows are flagged and never affect risk', () {
      final anomaly = ReservationAnomaly.fromJson(row(detectionMode: 'observe'));
      expect(anomaly.isObserve, isTrue);
    });

    test('tolerates missing optional fields with safe defaults', () {
      final anomaly = ReservationAnomaly.fromJson({
        'id': 'anomaly-2',
        'renter_id': 'renter-2',
        'facility_id': 'facility-2',
        'rule_key': 'abnormal_duration',
      });
      expect(anomaly.severity, AnomalySeverity.info);
      expect(anomaly.status, AnomalyStatus.open);
      expect(anomaly.detectionMode, 'active');
      expect(anomaly.evidenceSummary, isEmpty);
      expect(anomaly.renterName, '');
      expect(anomaly.localRiskScore, 0);
    });
  });

  group('RenterRiskSummary.fromJson', () {
    test('parses score, level, and top reasons', () {
      final summary = RenterRiskSummary.fromJson({
        'renter_id': 'renter-1',
        'admin_lane': 'external',
        'request_id': 'request-1',
        'facility_id': 'facility-1',
        'risk_score': 55,
        'risk_level': 'high',
        'active_anomaly_count': 2,
        'reservations_30d': 5,
        'successful_occurrences_30d': 3,
        'no_show_occurrences_30d': 2,
        'cancelled_occurrences_30d': 0,
        'late_cancellations_30d': 0,
        'payment_expirations_30d': 0,
        'top_reasons': [
          {
            'anomaly_id': 'anomaly-1',
            'rule_key': 'repeated_no_show',
            'title': 'Repeated no-shows',
            'points': 25,
          },
        ],
        'evaluation_pending': true,
      });

      expect(summary.riskScore, 55);
      expect(summary.riskLevel, RiskLevel.high);
      expect(summary.noShowOccurrences30d, 2);
      expect(summary.topReasons, hasLength(1));
      expect(summary.topReasons.first['rule_key'], 'repeated_no_show');
      expect(summary.evaluationPending, isTrue);
      expect(summary.portfolioLabel, 'Risk in your assigned portfolio');
    });

    test('defaults evaluation_pending to false and top_reasons to empty', () {
      final summary = RenterRiskSummary.fromJson({
        'renter_id': 'renter-1',
        'admin_lane': 'internal',
      });
      expect(summary.evaluationPending, isFalse);
      expect(summary.topReasons, isEmpty);
      expect(summary.riskLevel, RiskLevel.normal);
    });
  });

  group('AnomalyDetail.fromJson', () {
    test('parses nested anomaly, evidence, and restricted count', () {
      final detail = AnomalyDetail.fromJson({
        'anomaly': {
          'id': 'anomaly-1',
          'renter_id': 'renter-1',
          'facility_id': 'facility-1',
          'rule_key': 'repeated_no_show',
        },
        'evidence': [
          {
            'id': 'evidence-1',
            'request_id': 'request-1',
            'facility_id': 'facility-1',
            'evidence_role': 'no_show',
            'observed_at': '2026-08-20T00:00:00Z',
          },
        ],
        'restricted_evidence_count': 2,
      });

      expect(detail.anomaly.id, 'anomaly-1');
      expect(detail.evidence, hasLength(1));
      expect(detail.evidence.first.evidenceRole, 'no_show');
      expect(detail.restrictedEvidenceCount, 2);
    });
  });

  group('AnomalyPage.fromJson', () {
    test('parses rows, metrics, and a present cursor', () {
      final page = AnomalyPage.fromJson({
        'rows': [
          {
            'id': 'anomaly-1',
            'renter_id': 'renter-1',
            'facility_id': 'facility-1',
            'rule_key': 'repeated_no_show',
          },
        ],
        'metrics': {
          'open_count': 4,
          'high_count': 1,
          'critical_count': 0,
        },
        'next_cursor': {'last_detected_at': '2026-08-01T00:00:00Z', 'id': 'anomaly-1'},
        'lane': 'external',
      });

      expect(page.rows, hasLength(1));
      expect(page.metrics.openCount, 4);
      expect(page.metrics.highCount, 1);
      expect(page.nextCursor, isNotNull);
      expect(page.lane, 'external');
    });

    test('treats a missing cursor as the end of the list', () {
      final page = AnomalyPage.fromJson({'rows': [], 'metrics': {}});
      expect(page.rows, isEmpty);
      expect(page.metrics.openCount, 0);
      expect(page.nextCursor, isNull);
    });
  });
}
