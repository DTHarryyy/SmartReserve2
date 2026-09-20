import '../../util/campus_calendar.dart';
import 'reports_data.dart';

String utilisationCsv(
  ReportSnapshot snapshot, {
  required String exportedBy,
  bool stale = false,
}) => [
  ..._header(snapshot, exportedBy: exportedBy, stale: stale),
  'Section,Utilisation',
  'facility,building,category,booked_hours,available_hours,utilisation_percent',
  for (final row in snapshot.utilisation)
    [
      _cell(row.facilityName),
      _cell(row.building),
      _cell(row.category),
      row.bookedHours.toStringAsFixed(2),
      row.availableHours.toStringAsFixed(2),
      (row.fraction * 100).toStringAsFixed(2),
    ].join(','),
].join('\n');

String demandCsv(
  ReportSnapshot snapshot, {
  required String exportedBy,
  bool stale = false,
}) => [
  ..._header(snapshot, exportedBy: exportedBy, stale: stale),
  'Section,Demand',
  'weekday,hour,count',
  for (final cell in snapshot.demand)
    [_cell(_weekday(cell.day)), _cell(_block(cell.hour)), cell.count].join(','),
].join('\n');

String approvalPerformanceCsv(
  ReportSnapshot snapshot, {
  required String exportedBy,
  required bool canViewPerAdmin,
  bool stale = false,
}) => [
  ..._header(snapshot, exportedBy: exportedBy, stale: stale),
  'Section,Approval performance',
  'metric,value',
  'median_decision_hours,${snapshot.performance.medianHours?.toStringAsFixed(2) ?? ''}',
  'within_48_percent,${snapshot.performance.withinFortyEight == null ? '' : (snapshot.performance.withinFortyEight! * 100).toStringAsFixed(2)}',
  'expired_without_decision,${snapshot.performance.expired}',
  'declined,${snapshot.performance.declined}',
  'over_capacity,${snapshot.performance.overCapacity}',
  if (canViewPerAdmin) ...[
    '',
    'administrator,decisions,median_hours',
    for (final admin in snapshot.performance.perAdmin)
      [
        _cell(admin.who),
        admin.decisions,
        admin.median.toStringAsFixed(2),
      ].join(','),
  ],
].join('\n');

String revenueCsv(
  ReportSnapshot snapshot, {
  required String exportedBy,
  bool canViewRevenue = true,
  bool stale = false,
}) => [
  ..._header(snapshot, exportedBy: exportedBy, stale: stale),
  'Section,Revenue',
  if (!canViewRevenue)
    'Revenue is restricted to external administrators.'
  else ...[
    'metric,value_centavos,value_php',
    [
      'gross_verified',
      snapshot.revenue.grossVerifiedCentavos,
      _money(snapshot.revenue.grossVerifiedCentavos),
    ].join(','),
    [
      'refunds',
      snapshot.revenue.refundsCentavos,
      _money(snapshot.revenue.refundsCentavos),
    ].join(','),
    [
      'net_revenue',
      snapshot.revenue.netRevenueCentavos,
      _money(snapshot.revenue.netRevenueCentavos),
    ].join(','),
    [
      'outstanding',
      snapshot.revenue.outstandingCentavos,
      _money(snapshot.revenue.outstandingCentavos),
    ].join(','),
    '',
    'month,submitted_reservations,confirmed_reservations,completed_occurrences,booked_hours,utilisation_percent,gross_centavos,refunds_centavos,net_centavos',
    for (final row in snapshot.monthlyStatistics)
      [
        _cell(_month(row.monthStart)),
        row.submittedReservations,
        row.confirmedReservations,
        row.completedOccurrences,
        row.bookedHours.toStringAsFixed(2),
        (row.utilisationFraction * 100).toStringAsFixed(2),
        row.grossVerifiedCentavos,
        row.refundsCentavos,
        row.netRevenueCentavos,
      ].join(','),
  ],
].join('\n');

String dataQualityCsv(List<QualityIssue> issues) => [
  'Section,Data quality',
  'facility,severity,issue,why_it_matters,action',
  for (final issue in issues)
    [
      _cell(issue.facility.name),
      _cell(issue.severity.label),
      _cell(issue.issue),
      _cell(issue.impact),
      _cell(issue.actionLabel),
    ].join(','),
].join('\n');

String fullReportCsv({
  required ReportSnapshot snapshot,
  required List<QualityIssue> issues,
  required String exportedBy,
  required bool canViewPerAdmin,
  required bool canViewRevenue,
  bool stale = false,
  String? staleReason,
}) => [
  ..._header(
    snapshot,
    exportedBy: exportedBy,
    stale: stale,
    staleReason: staleReason,
  ),
  '',
  utilisationCsv(snapshot, exportedBy: exportedBy, stale: stale),
  '',
  revenueCsv(
    snapshot,
    exportedBy: exportedBy,
    canViewRevenue: canViewRevenue,
    stale: stale,
  ),
  '',
  demandCsv(snapshot, exportedBy: exportedBy, stale: stale),
  '',
  approvalPerformanceCsv(
    snapshot,
    exportedBy: exportedBy,
    canViewPerAdmin: canViewPerAdmin,
    stale: stale,
  ),
  '',
  dataQualityCsv(issues),
].join('\n');

List<String> _header(
  ReportSnapshot snapshot, {
  required String exportedBy,
  required bool stale,
  String? staleReason,
}) => [
  'Report,SmartReserve manual report',
  'Date range,${_cell('${formatDay(campusWallTime(snapshot.scope.from))} - ${formatDay(campusWallTime(snapshot.scope.to))}')}',
  'Category,${_cell(snapshot.scope.category ?? 'All categories')}',
  'Time zone,Asia/Manila',
  'Generated,${_cell(formatStamp(campusWallTime(snapshot.generatedAt)))}',
  'Exported by,${_cell(exportedBy)}',
  'Freshness,${stale ? 'Last verified data' : 'Verified'}',
  if (staleReason != null) 'Stale reason,${_cell(staleReason)}',
];

String _cell(Object? value) {
  final text = value?.toString() ?? '';
  return '"${text.replaceAll('"', '""')}"';
}

String _weekday(int value) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][value - 1];

String _block(int hour) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(hour)}:00-${two(hour + 2)}:00';
}

String _money(int centavos) => (centavos / 100).toStringAsFixed(2);

String _month(DateTime value) {
  final local = campusWallTime(value);
  return '${local.year}-${local.month.toString().padLeft(2, '0')}';
}
