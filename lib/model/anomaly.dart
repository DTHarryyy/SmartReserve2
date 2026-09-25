import '../theme/sr_tokens.dart';

enum AnomalySeverity {
  info('info', 'Info', SrTone.info),
  low('low', 'Low', SrTone.neutral),
  moderate('moderate', 'Moderate', SrTone.warning),
  high('high', 'High', SrTone.error),
  critical('critical', 'Critical', SrTone.error);

  const AnomalySeverity(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  static AnomalySeverity fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => AnomalySeverity.info,
  );
}

enum AnomalyStatus {
  open('open', 'Open'),
  acknowledged('acknowledged', 'Acknowledged'),
  resolved('resolved', 'Resolved'),
  falsePositive('false_positive', 'False positive');

  const AnomalyStatus(this.raw, this.label);

  final String raw;
  final String label;

  static AnomalyStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => AnomalyStatus.open,
  );
}

enum RiskLevel {
  normal('normal', 'Normal', SrTone.success),
  low('low', 'Low', SrTone.neutral),
  moderate('moderate', 'Moderate', SrTone.warning),
  high('high', 'High', SrTone.error),
  critical('critical', 'Critical', SrTone.error);

  const RiskLevel(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  static RiskLevel fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => RiskLevel.normal,
  );
}

class AnomalyFilters {
  const AnomalyFilters({
    this.statuses = const ['open', 'acknowledged'],
    this.severities = const [],
    this.rules = const [],
    this.includeObserve = false,
  });

  final List<String> statuses;
  final List<String> severities;
  final List<String> rules;
  final bool includeObserve;

  Map<String, dynamic> toJson() => {
    'statuses': statuses,
    'severities': severities,
    'rules': rules,
    'include_observe': includeObserve,
  };

  AnomalyFilters copyWith({
    List<String>? statuses,
    List<String>? severities,
    List<String>? rules,
    bool? includeObserve,
  }) => AnomalyFilters(
    statuses: statuses ?? this.statuses,
    severities: severities ?? this.severities,
    rules: rules ?? this.rules,
    includeObserve: includeObserve ?? this.includeObserve,
  );
}

class AnomalyMetrics {
  const AnomalyMetrics({
    this.openCount = 0,
    this.acknowledgedCount = 0,
    this.highCount = 0,
    this.criticalCount = 0,
    this.observeCount = 0,
    this.paymentCount = 0,
    this.needsReviewCount = 0,
  });

  factory AnomalyMetrics.fromJson(Map<String, dynamic> json) => AnomalyMetrics(
    openCount: _int(json['open_count']),
    acknowledgedCount: _int(json['acknowledged_count']),
    highCount: _int(json['high_count']),
    criticalCount: _int(json['critical_count']),
    observeCount: _int(json['observe_count']),
    paymentCount: _int(json['payment_count']),
    needsReviewCount: _int(json['needs_review_count']),
  );

  final int openCount;
  final int acknowledgedCount;
  final int highCount;
  final int criticalCount;
  final int observeCount;
  final int paymentCount;
  final int needsReviewCount;
}

class ReservationAnomaly {
  const ReservationAnomaly({
    required this.id,
    required this.renterId,
    required this.adminLane,
    required this.facilityId,
    required this.ruleKey,
    required this.correlationKey,
    required this.detectionMode,
    required this.severity,
    required this.status,
    required this.baseRiskPoints,
    required this.effectiveRiskPoints,
    required this.title,
    required this.explanation,
    required this.evidenceSummary,
    required this.windowStartedAt,
    required this.windowEndedAt,
    required this.lastContributingAt,
    required this.lastDetectedAt,
    required this.lastEvaluatedAt,
    this.renterName = '',
    this.facilityName = '',
    this.facilityBuilding = '',
    this.facilityRoom = '',
    this.localRiskScore = 0,
    this.localRiskLevel = RiskLevel.normal,
  });

  factory ReservationAnomaly.fromJson(Map<String, dynamic> json) =>
      ReservationAnomaly(
        id: '${json['id']}',
        renterId: '${json['renter_id']}',
        adminLane: '${json['admin_lane'] ?? ''}',
        facilityId: '${json['facility_id']}',
        ruleKey: '${json['rule_key']}',
        correlationKey: '${json['correlation_key'] ?? ''}',
        detectionMode: '${json['detection_mode'] ?? 'active'}',
        severity: AnomalySeverity.fromRaw('${json['severity'] ?? 'info'}'),
        status: AnomalyStatus.fromRaw('${json['status'] ?? 'open'}'),
        baseRiskPoints: _int(json['base_risk_points']),
        effectiveRiskPoints: _int(json['effective_risk_points']),
        title: '${json['title'] ?? ''}',
        explanation: '${json['explanation'] ?? ''}',
        evidenceSummary: Map<String, dynamic>.from(
          json['evidence_summary'] as Map? ?? const {},
        ),
        windowStartedAt: _date(json['window_started_at']) ?? DateTime.now(),
        windowEndedAt: _date(json['window_ended_at']) ?? DateTime.now(),
        lastContributingAt:
            _date(json['last_contributing_at']) ?? DateTime.now(),
        lastDetectedAt: _date(json['last_detected_at']) ?? DateTime.now(),
        lastEvaluatedAt: _date(json['last_evaluated_at']) ?? DateTime.now(),
        renterName: '${json['renter_name'] ?? ''}',
        facilityName: '${json['facility_name'] ?? ''}',
        facilityBuilding: '${json['facility_building'] ?? ''}',
        facilityRoom: '${json['facility_room'] ?? ''}',
        localRiskScore: _int(json['local_risk_score']),
        localRiskLevel: RiskLevel.fromRaw('${json['local_risk_level'] ?? ''}'),
      );

  final String id;
  final String renterId;
  final String adminLane;
  final String facilityId;
  final String ruleKey;
  final String correlationKey;
  final String detectionMode;
  final AnomalySeverity severity;
  final AnomalyStatus status;
  final int baseRiskPoints;
  final int effectiveRiskPoints;
  final String title;
  final String explanation;
  final Map<String, dynamic> evidenceSummary;
  final DateTime windowStartedAt;
  final DateTime windowEndedAt;
  final DateTime lastContributingAt;
  final DateTime lastDetectedAt;
  final DateTime lastEvaluatedAt;
  final String renterName;
  final String facilityName;
  final String facilityBuilding;
  final String facilityRoom;
  final int localRiskScore;
  final RiskLevel localRiskLevel;

  bool get isObserve => detectionMode == 'observe';
}

class AnomalyEvidence {
  const AnomalyEvidence({
    required this.id,
    required this.requestId,
    required this.facilityId,
    required this.evidenceRole,
    required this.observedAt,
    this.occurrenceId,
    this.facilityName = '',
    this.requestTitle = '',
    this.startsAt,
    this.endsAt,
    this.measuredValue,
  });

  factory AnomalyEvidence.fromJson(Map<String, dynamic> json) =>
      AnomalyEvidence(
        id: '${json['id']}',
        requestId: '${json['request_id']}',
        occurrenceId: json['occurrence_id'] as String?,
        facilityId: '${json['facility_id']}',
        facilityName: '${json['facility_name'] ?? ''}',
        evidenceRole: '${json['evidence_role'] ?? ''}',
        observedAt: _date(json['observed_at']) ?? DateTime.now(),
        measuredValue: (json['measured_value'] as num?)?.toDouble(),
        requestTitle: '${json['request_title'] ?? ''}',
        startsAt: _date(json['starts_at']),
        endsAt: _date(json['ends_at']),
      );

  final String id;
  final String requestId;
  final String? occurrenceId;
  final String facilityId;
  final String facilityName;
  final String evidenceRole;
  final DateTime observedAt;
  final double? measuredValue;
  final String requestTitle;
  final DateTime? startsAt;
  final DateTime? endsAt;
}

class RenterRiskSummary {
  const RenterRiskSummary({
    required this.renterId,
    required this.adminLane,
    required this.riskScore,
    required this.riskLevel,
    required this.activeAnomalyCount,
    required this.reservations30d,
    required this.successfulOccurrences30d,
    required this.noShowOccurrences30d,
    this.lateCheckIns30d = 0,
    required this.cancelledOccurrences30d,
    required this.lateCancellations30d,
    required this.paymentExpirations30d,
    required this.topReasons,
    this.requestId,
    this.facilityId,
    this.lastAdverseAt,
    this.lastEvaluatedAt,
    this.portfolioLabel = 'Risk in your assigned portfolio',
    this.evaluationPending = false,
    this.evaluationStalled = false,
  });

  factory RenterRiskSummary.fromJson(Map<String, dynamic> json) =>
      RenterRiskSummary(
        requestId: json['request_id'] as String?,
        renterId: '${json['renter_id'] ?? ''}',
        adminLane: '${json['admin_lane'] ?? ''}',
        facilityId: json['facility_id'] as String?,
        riskScore: _int(json['risk_score']),
        riskLevel: RiskLevel.fromRaw('${json['risk_level'] ?? 'normal'}'),
        activeAnomalyCount: _int(json['active_anomaly_count']),
        reservations30d: _int(json['reservations_30d']),
        successfulOccurrences30d: _int(json['successful_occurrences_30d']),
        noShowOccurrences30d: _int(json['no_show_occurrences_30d']),
        lateCheckIns30d: _int(json['late_check_ins_30d']),
        cancelledOccurrences30d: _int(json['cancelled_occurrences_30d']),
        lateCancellations30d: _int(json['late_cancellations_30d']),
        paymentExpirations30d: _int(json['payment_expirations_30d']),
        lastAdverseAt: _date(json['last_adverse_at']),
        lastEvaluatedAt: _date(json['last_evaluated_at']),
        topReasons: [
          for (final raw in (json['top_reasons'] as List? ?? const []))
            Map<String, dynamic>.from(raw as Map),
        ],
        portfolioLabel:
            '${json['portfolio_label'] ?? 'Risk in your assigned portfolio'}',
        evaluationPending: json['evaluation_pending'] as bool? ?? false,
        evaluationStalled: json['evaluation_stalled'] as bool? ?? false,
      );

  final String? requestId;
  final String renterId;
  final String adminLane;
  final String? facilityId;
  final int riskScore;
  final RiskLevel riskLevel;
  final int activeAnomalyCount;
  final int reservations30d;
  final int successfulOccurrences30d;
  final int noShowOccurrences30d;
  final int lateCheckIns30d;
  final int cancelledOccurrences30d;
  final int lateCancellations30d;
  final int paymentExpirations30d;
  final DateTime? lastAdverseAt;
  final DateTime? lastEvaluatedAt;
  final List<Map<String, dynamic>> topReasons;
  final String portfolioLabel;
  final bool evaluationPending;
  final bool evaluationStalled;
}

class AnomalyDetail {
  const AnomalyDetail({
    required this.anomaly,
    required this.evidence,
    required this.restrictedEvidenceCount,
  });

  factory AnomalyDetail.fromJson(Map<String, dynamic> json) => AnomalyDetail(
    anomaly: ReservationAnomaly.fromJson(
      Map<String, dynamic>.from(json['anomaly'] as Map? ?? const {}),
    ),
    evidence: [
      for (final raw in (json['evidence'] as List? ?? const []))
        AnomalyEvidence.fromJson(Map<String, dynamic>.from(raw as Map)),
    ],
    restrictedEvidenceCount: _int(json['restricted_evidence_count']),
  );

  final ReservationAnomaly anomaly;
  final List<AnomalyEvidence> evidence;
  final int restrictedEvidenceCount;
}

class AnomalyPage {
  const AnomalyPage({
    required this.rows,
    required this.metrics,
    this.nextCursor,
    this.lane = '',
  });

  factory AnomalyPage.fromJson(Map<String, dynamic> json) => AnomalyPage(
    rows: [
      for (final raw in (json['rows'] as List? ?? const []))
        ReservationAnomaly.fromJson(Map<String, dynamic>.from(raw as Map)),
    ],
    metrics: AnomalyMetrics.fromJson(
      Map<String, dynamic>.from(json['metrics'] as Map? ?? const {}),
    ),
    nextCursor: json['next_cursor'] is Map
        ? Map<String, dynamic>.from(json['next_cursor'] as Map)
        : null,
    lane: '${json['lane'] ?? ''}',
  );

  final List<ReservationAnomaly> rows;
  final AnomalyMetrics metrics;
  final Map<String, dynamic>? nextCursor;
  final String lane;
}

int _int(Object? value) => switch (value) {
  num n => n.toInt(),
  String s => int.tryParse(s) ?? 0,
  _ => 0,
};

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;
