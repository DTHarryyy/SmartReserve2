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
      ReportRange.semester => DateTime.utc(
        end.month >= 8 ? end.year : end.year - 1,
        8,
        1,
      ),
    };
    return ReportScope(range: range, from: start, to: end, category: category);
  }
}

class ReportSnapshot {
  const ReportSnapshot({
    required this.utilisation,
    required this.demand,
    required this.performance,
  });

  final List<ReportUtilisation> utilisation;
  final List<ReportDemandCell> demand;
  final ReportPerformance performance;

  factory ReportSnapshot.fromJson(Map<String, dynamic> json) => ReportSnapshot(
    utilisation: ((json['utilisation'] as List?) ?? const [])
        .map(
          (row) =>
              ReportUtilisation.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(),
    demand: ((json['demand'] as List?) ?? const [])
        .map(
          (row) =>
              ReportDemandCell.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(),
    performance: ReportPerformance.fromJson(
      Map<String, dynamic>.from((json['performance'] as Map?) ?? const {}),
    ),
  );
}

class ReportUtilisation {
  const ReportUtilisation({
    required this.facilityId,
    required this.bookedHours,
    required this.availableHours,
    required this.fraction,
  });
  final String facilityId;
  final double bookedHours;
  final double availableHours;
  final double fraction;
  factory ReportUtilisation.fromJson(Map<String, dynamic> json) =>
      ReportUtilisation(
        facilityId: '${json['facility_id']}',
        bookedHours: (json['booked_hours'] as num?)?.toDouble() ?? 0,
        availableHours: (json['available_hours'] as num?)?.toDouble() ?? 0,
        fraction: (json['fraction'] as num?)?.toDouble() ?? 0,
      );
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
        day: (json['day'] as num?)?.toInt() ?? 1,
        hour: (json['hour'] as num?)?.toInt() ?? 7,
        count: (json['count'] as num?)?.toInt() ?? 0,
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
  final List<({String who, int decisions, double median})> perAdmin;
  factory ReportPerformance.fromJson(Map<String, dynamic> json) =>
      ReportPerformance(
        medianHours: (json['median_hours'] as num?)?.toDouble(),
        withinFortyEight: (json['within_48'] as num?)?.toDouble(),
        expired: (json['expired'] as num?)?.toInt() ?? 0,
        declined: (json['declined'] as num?)?.toInt() ?? 0,
        overCapacity: (json['over_capacity'] as num?)?.toInt() ?? 0,
        perAdmin: ((json['per_admin'] as List?) ?? const []).map((row) {
          final value = Map<String, dynamic>.from(row as Map);
          return (
            who: '${value['name']}',
            decisions: (value['decisions'] as num?)?.toInt() ?? 0,
            median: (value['median_hours'] as num?)?.toDouble() ?? 0,
          );
        }).toList(),
      );
}

List<Utilisation> utilisationFromReport(
  ReportSnapshot snapshot,
  List<Facility> facilities,
) {
  final byId = {for (final facility in facilities) facility.id: facility};
  return [
    for (final row in snapshot.utilisation)
      if (byId[row.facilityId] case final facility?)
        Utilisation(
          facility: facility,
          bookedHours: row.bookedHours,
          availableHours: row.availableHours,
        ),
  ]..sort((a, b) => a.fraction.compareTo(b.fraction));
}

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
    required this.facility,
    required this.bookedHours,
    required this.availableHours,
  });

  final Facility facility;
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
        facility: facility,
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

  final List<({String who, int decisions, double median})> perAdmin;

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
