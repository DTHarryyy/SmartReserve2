import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/reservation.dart';
import '../../util/geo.dart';
import '../../util/campus_calendar.dart';

enum ReportRange {
  week('Last 7 days', 1),
  month('Last 30 days', 4),
  semester('This semester', 18);

  const ReportRange(this.label, this.weeks);

  final String label;

  final int weeks;
}

class ReportScope {
  const ReportScope({
    required this.range,
    required this.from,
    required this.to,
    this.category,
  });

  final ReportRange range;
  final DateTime from;
  final DateTime to;
  final String? category;

  factory ReportScope.forRange(
    ReportRange range, {
    String? category,
    DateTime? now,
  }) {
    final end = campusInstant(now ?? campusNow());
    final start = switch (range) {
      ReportRange.week => end.subtract(const Duration(days: 7)),
      ReportRange.month => end.subtract(const Duration(days: 30)),
      ReportRange.semester => campusInstant(
        DateTime(end.month >= 8 ? end.year : end.year - 1, 8, 1),
      ),
    };
    return ReportScope(range: range, from: start, to: end, category: category);
  }

  bool matches(ReportScope other) =>
      range == other.range &&
      from.isAtSameMomentAs(other.from) &&
      to.isAtSameMomentAs(other.to) &&
      category == other.category;

  bool hasSameSelection(ReportScope other) =>
      range == other.range && category == other.category;
}

class ReportSnapshot {
  const ReportSnapshot({
    required this.scope,
    required this.generatedAt,
    required this.bookedHours,
    required this.availableHours,
    required this.fraction,
    required this.utilisation,
    required this.bookedOccurrences,
    required this.demand,
    required this.performance,
  });

  final ReportScope scope;
  final DateTime generatedAt;
  final double bookedHours;
  final double availableHours;
  final double fraction;
  final List<ReportUtilisation> utilisation;
  final List<ReportBookedOccurrence> bookedOccurrences;
  final List<ReportDemandCell> demand;
  final ReportPerformance performance;

  factory ReportSnapshot.fromJson(
    Map<String, dynamic> json, {
    required ReportScope expectedScope,
  }) {
    final from = _date(json, 'from');
    final to = _date(json, 'to');
    final category = _nullableString(json, 'category');
    if (!from.isAtSameMomentAs(expectedScope.from) ||
        !to.isAtSameMomentAs(expectedScope.to) ||
        category != expectedScope.category) {
      throw const FormatException('Report response did not match its request.');
    }
    final summary = _map(json, 'summary');
    final rows = _list(json, 'utilisation')
        .map(
          (row) => ReportUtilisation.fromJson(_asMap(row, 'utilisation row')),
        )
        .toList(growable: false);
    final occurrences = _list(json, 'booked_occurrences')
        .map(
          (row) =>
              ReportBookedOccurrence.fromJson(_asMap(row, 'booked occurrence')),
        )
        .toList(growable: false);
    final demand = _list(json, 'demand')
        .map((row) => ReportDemandCell.fromJson(_asMap(row, 'demand cell')))
        .toList(growable: false);
    final demandKeys = {for (final cell in demand) '${cell.day}:${cell.hour}'};
    if (demand.length != 49 || demandKeys.length != 49) {
      throw const FormatException('Report demand grid is incomplete.');
    }
    final bookedHours = _number(summary, 'booked_hours', min: 0);
    final availableHours = _number(summary, 'available_hours', min: 0);
    final fraction = _number(summary, 'fraction', min: 0, max: 1);
    final rowIds = {for (final row in rows) row.facilityId};
    if (rowIds.length != rows.length ||
        occurrences.any((row) => !rowIds.contains(row.facilityId))) {
      throw const FormatException('Report facility rows do not reconcile.');
    }
    final rowBooked = rows.fold<double>(0, (sum, row) => sum + row.bookedHours);
    final rowAvailable = rows.fold<double>(
      0,
      (sum, row) => sum + row.availableHours,
    );
    final occurrenceBooked = occurrences.fold<double>(
      0,
      (sum, row) => sum + row.bookedHours,
    );
    final expectedFraction = availableHours == 0
        ? 0.0
        : (bookedHours / availableHours).clamp(0.0, 1.0);
    final roundingTolerance = .011 * (occurrences.length + rows.length + 1);
    if ((rowBooked - bookedHours).abs() > roundingTolerance ||
        (rowAvailable - availableHours).abs() > roundingTolerance ||
        (occurrenceBooked - bookedHours).abs() > roundingTolerance ||
        (expectedFraction - fraction).abs() > .0001) {
      throw const FormatException('Report totals do not reconcile.');
    }
    return ReportSnapshot(
      scope: expectedScope,
      generatedAt: _date(json, 'generated_at'),
      bookedHours: bookedHours,
      availableHours: availableHours,
      fraction: fraction,
      utilisation: rows,
      bookedOccurrences: occurrences,
      demand: demand,
      performance: ReportPerformance.fromJson(_map(json, 'performance')),
    );
  }

  bool matches(ReportScope other) => scope.matches(other);

  bool hasSameSelection(ReportScope other) => scope.hasSameSelection(other);
}

class ReportUtilisation {
  const ReportUtilisation({
    required this.facilityId,
    required this.facilityName,
    required this.building,
    required this.category,
    required this.bookedHours,
    required this.availableHours,
    required this.fraction,
  });
  final String facilityId;
  final String facilityName;
  final String building;
  final String category;
  final double bookedHours;
  final double availableHours;
  final double fraction;
  factory ReportUtilisation.fromJson(Map<String, dynamic> json) =>
      ReportUtilisation(
        facilityId: _string(json, 'facility_id'),
        facilityName: _string(json, 'facility_name'),
        building: _string(json, 'building', allowEmpty: true),
        category: _string(json, 'category'),
        bookedHours: _number(json, 'booked_hours', min: 0),
        availableHours: _number(json, 'available_hours', min: 0),
        fraction: _number(json, 'fraction', min: 0, max: 1),
      );
}

class ReportBookedOccurrence {
  const ReportBookedOccurrence({
    required this.occurrenceId,
    required this.requestId,
    required this.facilityId,
    required this.requester,
    required this.purpose,
    required this.requestStatus,
    required this.startsAt,
    required this.endsAt,
    required this.bookedHours,
  });

  final String occurrenceId;
  final String requestId;
  final String facilityId;
  final String requester;
  final String purpose;
  final String requestStatus;
  final DateTime startsAt;
  final DateTime endsAt;
  final double bookedHours;

  factory ReportBookedOccurrence.fromJson(Map<String, dynamic> json) {
    final startsAt = _date(json, 'starts_at');
    final endsAt = _date(json, 'ends_at');
    if (!startsAt.isBefore(endsAt)) {
      throw const FormatException('Booked occurrence has an invalid range.');
    }
    return ReportBookedOccurrence(
      occurrenceId: _string(json, 'occurrence_id'),
      requestId: _string(json, 'request_id'),
      facilityId: _string(json, 'facility_id'),
      requester: _string(json, 'requester'),
      purpose: _string(json, 'purpose'),
      requestStatus: _string(json, 'request_status'),
      startsAt: startsAt,
      endsAt: endsAt,
      bookedHours: _number(json, 'booked_hours', min: 0),
    );
  }
}

class ReportDemandCell {
  const ReportDemandCell({
    required this.day,
    required this.hour,
    required this.count,
  });
  final int day;
  final int hour;
  final int count;
  factory ReportDemandCell.fromJson(Map<String, dynamic> json) =>
      ReportDemandCell(
        day: _integer(json, 'day', min: 1, max: 7),
        hour: _integer(json, 'hour', min: 7, max: 19),
        count: _integer(json, 'count', min: 0),
      );
}

class ReportPerformance {
  const ReportPerformance({
    this.medianHours,
    this.withinFortyEight,
    required this.expired,
    required this.declined,
    required this.overCapacity,
    required this.perAdmin,
  });
  final double? medianHours;
  final double? withinFortyEight;
  final int expired;
  final int declined;
  final int overCapacity;
  final List<({String? id, String who, int decisions, double median})> perAdmin;
  factory ReportPerformance.fromJson(Map<String, dynamic> json) =>
      ReportPerformance(
        medianHours: _nullableNumber(json, 'median_hours', min: 0),
        withinFortyEight: _nullableNumber(json, 'within_48', min: 0, max: 1),
        expired: _integer(json, 'expired', min: 0),
        declined: _integer(json, 'declined', min: 0),
        overCapacity: _integer(json, 'over_capacity', min: 0),
        perAdmin: _list(json, 'per_admin').map((row) {
          final value = _asMap(row, 'administrator performance');
          return (
            id: _nullableString(value, 'admin_id'),
            who: _string(value, 'name'),
            decisions: _integer(value, 'decisions', min: 0),
            median: _number(value, 'median_hours', min: 0),
          );
        }).toList(),
      );
}

List<Utilisation> utilisationFromReport(ReportSnapshot snapshot) => [
  for (final row in snapshot.utilisation)
    Utilisation(
      facilityId: row.facilityId,
      facilityName: row.facilityName,
      building: row.building,
      category: row.category,
      bookedHours: row.bookedHours,
      availableHours: row.availableHours,
    ),
]..sort((a, b) => a.fraction.compareTo(b.fraction));

DemandHeatmap demandFromReport(ReportSnapshot snapshot) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const hours = ['07', '09', '11', '13', '15', '17', '19'];
  final cells = [for (var day = 0; day < 7; day++) List.filled(7, 0)];
  for (final cell in snapshot.demand) {
    final hour = ((cell.hour - 7) ~/ 2);
    if (cell.day >= 1 && cell.day <= 7 && hour >= 0 && hour < 7) {
      cells[cell.day - 1][hour] = cell.count;
    }
  }
  return DemandHeatmap(cells, hours, days);
}

ApprovalPerformance performanceFromReport(ReportSnapshot snapshot) =>
    ApprovalPerformance(
      medianHours: snapshot.performance.medianHours,
      withinFortyEight: snapshot.performance.withinFortyEight ?? 0,
      expired: snapshot.performance.expired,
      perAdmin: snapshot.performance.perAdmin,
    );

class Utilisation {
  const Utilisation({
    required this.facilityId,
    required this.facilityName,
    required this.building,
    required this.category,
    required this.bookedHours,
    required this.availableHours,
  });

  final String facilityId;
  final String facilityName;
  final String building;
  final String category;
  final double bookedHours;
  final double availableHours;

  double get fraction =>
      availableHours <= 0 ? 0 : (bookedHours / availableHours).clamp(0.0, 1.0);

  int get percent => (fraction * 100).round();
}

List<Utilisation> utilisationFor({
  required List<Facility> facilities,
  required List<ReservationRequest> requests,
  required List<Booking> bookings,
  required ReportRange range,
  required String category,
}) {
  final rows = <Utilisation>[];
  for (final facility in facilities) {
    if (category != 'All categories' && facility.category != category) continue;

    var booked = 0.0;
    for (final r in requests) {
      if (r.facility == facility.name && r.status == RequestStatus.approved) {
        booked += r.endAt - r.startAt;
      }
    }
    for (final b in bookings) {
      if (b.facility == facility.name) booked += b.endAt - b.startAt;
    }

    booked *= range.weeks;

    final available =
        facility.operatingHoursPerDay.toDouble() *
        facility.openDaysPerWeek *
        range.weeks;

    rows.add(
      Utilisation(
        facilityId: facility.id,
        facilityName: facility.name,
        building: facility.building,
        category: facility.category,
        bookedHours: booked,
        availableHours: available,
      ),
    );
  }
  rows.sort((a, b) => a.fraction.compareTo(b.fraction));
  return rows;
}

class DemandHeatmap {
  DemandHeatmap(this.cells, this.hours, this.days);

  final List<List<int>> cells;
  final List<String> hours;
  final List<String> days;

  int get peak => cells.expand((row) => row).fold(0, (a, b) => a > b ? a : b);
}

DemandHeatmap demandFor(List<ReservationRequest> requests) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final blocks = <int>[for (var h = dayStartHour; h < dayEndHour; h += 2) h];
  final hours = [for (final h in blocks) h.toString().padLeft(2, '0')];
  final cells = [
    for (var i = 0; i < days.length; i++) List.filled(blocks.length, 0),
  ];

  for (final r in requests) {
    final day = days.indexOf(r.date.split(' ').first);
    if (day < 0) continue;
    for (var i = 0; i < blocks.length; i++) {
      final from = blocks[i].toDouble();
      final to = from + 2;
      if (r.startAt < to && from < r.endAt) cells[day][i]++;
    }
  }
  return DemandHeatmap(cells, hours, days);
}

class ApprovalPerformance {
  const ApprovalPerformance({
    required this.medianHours,
    required this.withinFortyEight,
    required this.expired,
    required this.perAdmin,
  });

  final double? medianHours;

  final double withinFortyEight;
  final int expired;

  final List<({String? id, String who, int decisions, double median})> perAdmin;

  String get medianLabel => medianHours == null
      ? 'Insufficient data'
      : (medianHours! < 24
            ? '${medianHours!.round()} h'
            : '${(medianHours! / 24).toStringAsFixed(1)} d');
}

double? hoursAgo(String? text) {
  if (text == null) return null;
  final lower = text.toLowerCase();
  if (lower.contains('just now') || lower.contains('now')) return 0;
  if (lower.startsWith('yesterday')) return 24;
  final match = RegExp(r'(\d+)\s*(minute|hour|day|week)').firstMatch(lower);
  if (match == null) return null;
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'minute' => n / 60,
    'hour' => n.toDouble(),
    'day' => n * 24.0,
    _ => n * 168.0,
  };
}

ApprovalPerformance performanceFor(List<ReservationRequest> requests) {
  final latencies = <double>[];
  final byAdmin = <String, List<double>>{};

  for (final r in requests) {
    if (r.status == RequestStatus.pending) continue;
    final submitted = hoursAgo(r.submitted);
    final decided = hoursAgo(r.decidedAt);
    if (submitted == null || decided == null) continue;
    final latency = submitted - decided;
    if (latency < 0) continue;
    latencies.add(latency);
    byAdmin.putIfAbsent(r.decidedBy ?? 'Unattributed', () => []).add(latency);
  }

  double? median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  return ApprovalPerformance(
    medianHours: median(latencies),
    withinFortyEight: latencies.isEmpty
        ? 0
        : latencies.where((h) => h <= 48).length / latencies.length,

    expired: requests.where((r) => r.status == RequestStatus.expired).length,
    perAdmin: [
      for (final entry in byAdmin.entries)
        (
          id: null,
          who: entry.key,
          decisions: entry.value.length,
          median: median(entry.value) ?? 0,
        ),
    ]..sort((a, b) => b.decisions.compareTo(a.decisions)),
  );
}

enum QualitySeverity {
  blocking('BLOCKING'),
  warning('CHECK'),
  minor('MINOR');

  const QualitySeverity(this.label);

  final String label;
}

class QualityIssue {
  const QualityIssue({
    required this.facility,
    required this.severity,
    required this.issue,
  });

  final Facility facility;
  final QualitySeverity severity;
  final String issue;
}

List<QualityIssue> qualityIssuesFor(List<Facility> facilities) {
  final issues = <QualityIssue>[];
  for (final f in facilities) {
    if (f.coords == null) {
      issues.add(
        QualityIssue(
          facility: f,
          severity: QualitySeverity.blocking,
          issue: 'No pin at all — students cannot get directions to this room.',
        ),
      );
      continue;
    }
    if (!inPolygon(f.coords!, campus.boundary)) {
      issues.add(
        QualityIssue(
          facility: f,
          severity: QualitySeverity.blocking,
          issue:
              'Pinned ${formatMetres(haversine(f.coords!, campus.center))} '
              'from the campus centre, outside the boundary.',
        ),
      );
      continue;
    }
    final building = buildingNamed(f.building);
    if (building != null && building.mapped) {
      final metres = haversine(f.coords!, building.coords);
      if (metres > buildingProximityLimit) {
        issues.add(
          QualityIssue(
            facility: f,
            severity: QualitySeverity.warning,
            issue:
                '${formatMetres(metres)} from ${building.name} — further than '
                'a room in that building should be.',
          ),
        );
        continue;
      }
    }
    if ((f.accuracy ?? 0) > accuracyWarnLimit) {
      issues.add(
        QualityIssue(
          facility: f,
          severity: QualitySeverity.warning,
          issue:
              'Pin precision is ±${f.accuracy} m — too loose to find a '
              'doorway.',
        ),
      );
      continue;
    }
    if (f.photoCount == 0) {
      issues.add(
        QualityIssue(
          facility: f,
          severity: QualitySeverity.minor,
          issue: 'No photos, so the catalogue card has nothing to show.',
        ),
      );
    }
  }
  return issues;
}

String formatUtilisationPercent(double fraction) {
  final percent = fraction.clamp(0.0, 1.0) * 100;
  if (percent == 0 || percent >= 10) return '${percent.round()}%';
  return '${percent.toStringAsFixed(1)}%';
}

String reportCsv(ReportSnapshot snapshot, {required String exportedBy}) {
  String cell(Object? value) {
    final text = value?.toString() ?? '';
    return '"${text.replaceAll('"', '""')}"';
  }

  final rows = <String>[
    'facility,building,category,booked_hours,available_hours,utilisation',
    for (final row in snapshot.utilisation)
      [
        cell(row.facilityName),
        cell(row.building),
        cell(row.category),
        row.bookedHours.toStringAsFixed(2),
        row.availableHours.toStringAsFixed(2),
        (row.fraction * 100).toStringAsFixed(2),
      ].join(','),
    '',
    'from,to,category,generated_at,exported_by,total_booked_hours,total_available_hours,overall_utilisation',
    [
      snapshot.scope.from.toUtc().toIso8601String(),
      snapshot.scope.to.toUtc().toIso8601String(),
      cell(snapshot.scope.category ?? 'All categories'),
      snapshot.generatedAt.toUtc().toIso8601String(),
      cell(exportedBy),
      snapshot.bookedHours.toStringAsFixed(2),
      snapshot.availableHours.toStringAsFixed(2),
      (snapshot.fraction * 100).toStringAsFixed(2),
    ].join(','),
  ];
  return rows.join('\n');
}

Map<String, dynamic> _asMap(Object? value, String label) {
  if (value is! Map) throw FormatException('Invalid $label.');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _map(Map<String, dynamic> json, String key) =>
    _asMap(json[key], key);

List<dynamic> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('Invalid $key.');
  return value;
}

String _string(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String? _nullableString(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) throw FormatException('Missing $key.');
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

DateTime _date(Map<String, dynamic> json, String key) {
  final value = json[key];
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw FormatException('Invalid $key.');
  return parsed;
}

double _number(
  Map<String, dynamic> json,
  String key, {
  double? min,
  double? max,
}) {
  final value = json[key];
  if (value is! num) throw FormatException('Invalid $key.');
  final number = value.toDouble();
  if (!number.isFinite ||
      (min != null && number < min) ||
      (max != null && number > max)) {
    throw FormatException('Invalid $key.');
  }
  return number;
}

double? _nullableNumber(
  Map<String, dynamic> json,
  String key, {
  double? min,
  double? max,
}) {
  if (!json.containsKey(key)) throw FormatException('Missing $key.');
  return json[key] == null ? null : _number(json, key, min: min, max: max);
}

int _integer(Map<String, dynamic> json, String key, {int? min, int? max}) {
  final number = _number(json, key, min: min?.toDouble(), max: max?.toDouble());
  if (number != number.roundToDouble()) throw FormatException('Invalid $key.');
  return number.toInt();
}
