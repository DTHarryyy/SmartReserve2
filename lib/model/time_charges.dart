/// Extra-time billing: campus after-hours use, approved extensions and
/// overtime at checkout. The pure functions below mirror
/// `after_hours_minutes()` and `extra_time_billable_minutes()` in
/// 20260930055936_after_hours_extension_overtime_checkout.sql so the app can
/// show live estimates; the server always computes the amount that is billed.
///
/// All [DateTime] values are campus wall times (see `campusWallTime`).
library;

/// Campus (internal-lane) use is free until this hour, Manila time.
const kCampusFreeHoursEndHour = 17;

/// Overtime at or below this many minutes is not billed.
const kDefaultOvertimeGraceMinutes = 15;

DateTime campusFreeHoursEnd(DateTime wallTime) =>
    DateTime.utc(wallTime.year, wallTime.month, wallTime.day, kCampusFreeHoursEndHour);

int _ceilMinutes(Duration duration) =>
    duration.isNegative ? 0 : (duration.inSeconds / 60).ceil();

/// Minutes of `[start, end)` after 5:00 PM on [start]'s day.
int afterHoursMinutes(DateTime start, DateTime end) {
  final cutoff = campusFreeHoursEnd(start);
  final from = start.isAfter(cutoff) ? start : cutoff;
  return end.isAfter(from) ? _ceilMinutes(end.difference(from)) : 0;
}

/// Billable minutes (always whole hours) for time added between [oldEnd] and
/// [newEnd]. Campus bookings only pay for time after 5:00 PM; renters pay for
/// every minute. [graceMinutes] is forgiven entirely when the billable time
/// does not exceed it (overtime); extensions pass 0.
int extraTimeBillableMinutes({
  required bool campus,
  required DateTime oldEnd,
  required DateTime newEnd,
  int graceMinutes = 0,
}) {
  if (!newEnd.isAfter(oldEnd)) return 0;
  final raw = campus
      ? afterHoursMinutes(oldEnd, newEnd)
      : _ceilMinutes(newEnd.difference(oldEnd));
  if (raw <= (graceMinutes < 0 ? 0 : graceMinutes)) return 0;
  return (raw / 60).ceil() * 60;
}

int extraTimeAmountCentavos({
  required int billableMinutes,
  required int hourlyRateCentavos,
}) => (billableMinutes ~/ 60) * hourlyRateCentavos;

enum TimeChargeKind {
  extension('extension', 'Extension'),
  overtime('overtime', 'Overtime');

  const TimeChargeKind(this.raw, this.label);
  final String raw;
  final String label;

  static TimeChargeKind fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => TimeChargeKind.extension,
  );
}

enum TimeChargeStatus {
  requested('requested', 'Waiting for approval'),
  approved('approved', 'Approved'),
  declined('declined', 'Declined'),
  cancelled('cancelled', 'Withdrawn'),
  waived('waived', 'Waived');

  const TimeChargeStatus(this.raw, this.label);
  final String raw;
  final String label;

  static TimeChargeStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => TimeChargeStatus.requested,
  );
}

/// One row of `reservation_time_charges`, with times as campus wall times.
class ReservationTimeCharge {
  const ReservationTimeCharge({
    required this.id,
    required this.occurrenceId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.requestedMinutes,
    this.previousEndsAt,
    this.newEndsAt,
    this.actualEndAt,
    this.rawOverMinutes,
    this.billableMinutes = 0,
    this.hourlyRateCentavos = 0,
    this.amountCentavos = 0,
    this.reason,
    this.decisionReason,
    this.decidedAt,
  });

  final String id;
  final String occurrenceId;
  final TimeChargeKind kind;
  final TimeChargeStatus status;
  final DateTime createdAt;
  final int? requestedMinutes;
  final DateTime? previousEndsAt;
  final DateTime? newEndsAt;
  final DateTime? actualEndAt;
  final int? rawOverMinutes;
  final int billableMinutes;
  final int hourlyRateCentavos;
  final int amountCentavos;
  final String? reason;
  final String? decisionReason;
  final DateTime? decidedAt;

  bool get isPending => status == TimeChargeStatus.requested;

  /// Counts toward what the requester owes.
  bool get isBillable => status == TimeChargeStatus.approved;

  int get billableHours => billableMinutes ~/ 60;
}
