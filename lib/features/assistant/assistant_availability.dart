library;

import 'dart:math' as math;

import '../../model/facility.dart';
import '../../util/campus_calendar.dart';

class BusyWindow {
  const BusyWindow(this.startHour, this.endHour);
  final double startHour;
  final double endHour;
}

class FreeSlot {
  const FreeSlot({
    required this.day,
    required this.startHour,
    required this.endHour,
  });
  final DateTime day;
  final double startHour;
  final double endHour;

  String get label =>
      '${formatClockHour(startHour)}–${formatClockHour(endHour)}';
}

class AvailableBookingDay {
  const AvailableBookingDay({
    required this.day,
    required this.firstAvailableSlot,
    required this.slotCount,
  });

  final DateTime day;
  final FreeSlot firstAvailableSlot;
  final int slotCount;
}

enum SlotIssue {
  closedDay,
  outsideHours,
  tooLong,
  inPast,
  beyondAdvance,
  overCapacity,
  clash,
  facilityUnavailable,
  zeroDuration,
}

class SlotVerdict {
  const SlotVerdict(this.issues);
  final List<SlotIssue> issues;
  bool get ok => issues.isEmpty;
}

String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

String formatClockHour(double hours) {
  return formatClock12(hours);
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

double _ceilToStep(double hour, double step) => (hour / step).ceil() * step;

List<BusyWindow> _inflate(List<BusyWindow> busy, int bufferMinutes) {
  final bufferHours = (2 * bufferMinutes) / 60;
  return [
    for (final b in busy)
      BusyWindow(b.startHour - bufferHours, b.endHour + bufferHours),
  ];
}

List<FreeSlot> freeSlotsForDay({
  required Facility facility,
  required DateTime day,
  required List<BusyWindow> busy,
  required double durationHours,
  DateTime? nowWall,
  int limit = 6,
  double step = 0.5,
}) {
  if (durationHours <= 0) return const [];
  if ((durationHours * 60).round() > facility.maxDurationMinutes) {
    return const [];
  }
  if (!facility.opensOn(day)) return const [];

  final open = facility.openHour.toDouble();
  final close = facility.closeHour.toDouble();
  var lo = open;
  if (nowWall != null && _isSameDay(day, nowWall)) {
    final nowHour = nowWall.hour + nowWall.minute / 60;
    lo = math.max(lo, _ceilToStep(nowHour, step));
  }

  final inflated = _inflate(busy, facility.bookingBufferMinutes);
  final slots = <FreeSlot>[];
  var start = lo;
  while (start + durationHours <= close && slots.length < limit) {
    final end = start + durationHours;
    final clashes = inflated.any((b) => b.startHour < end && start < b.endHour);
    if (!clashes) {
      slots.add(FreeSlot(day: day, startHour: start, endHour: end));
    }
    start += step;
  }
  return slots;
}

List<AvailableBookingDay> availableBookingDaysForFacility({
  required Facility facility,
  required DateTime fromWall,
  required DateTime toWall,
  required Map<String, List<BusyWindow>> busy,
  required double durationHours,
  required DateTime nowWall,
  double step = 0.5,
}) {
  final today = DateTime(nowWall.year, nowWall.month, nowWall.day);
  var day = DateTime(fromWall.year, fromWall.month, fromWall.day);
  if (day.isBefore(today)) day = today;
  final end = DateTime(toWall.year, toWall.month, toWall.day);
  final days = <AvailableBookingDay>[];

  while (!day.isAfter(end)) {
    if (facility.opensOn(day)) {
      final key = '${facility.id}|${dayKey(day)}';
      final slots = freeSlotsForDay(
        facility: facility,
        day: day,
        busy: busy[key] ?? busy[dayKey(day)] ?? const [],
        durationHours: durationHours,
        nowWall: nowWall,
        limit: 200,
        step: step,
      );
      if (slots.isNotEmpty) {
        days.add(
          AvailableBookingDay(
            day: day,
            firstAvailableSlot: slots.first,
            slotCount: slots.length,
          ),
        );
      }
    }
    day = day.add(const Duration(days: 1));
  }

  return days;
}

SlotVerdict checkSlot({
  required Facility facility,
  required DateTime day,
  required double startHour,
  required double endHour,
  required int heads,
  required List<BusyWindow> busy,
  required DateTime nowWall,
}) {
  final issues = <SlotIssue>[];

  if (endHour <= startHour) {
    issues.add(SlotIssue.zeroDuration);
  }
  if (facility.state == FacilityState.maintenance) {
    issues.add(SlotIssue.facilityUnavailable);
  }
  if (!facility.opensOn(day)) {
    issues.add(SlotIssue.closedDay);
  }
  if (startHour < facility.openHour || endHour > facility.closeHour) {
    issues.add(SlotIssue.outsideHours);
  }
  final durationMinutes = ((endHour - startHour) * 60).round();
  if (durationMinutes > facility.maxDurationMinutes) {
    issues.add(SlotIssue.tooLong);
  }
  if (heads > facility.capacity) {
    issues.add(SlotIssue.overCapacity);
  }

  final today = DateTime(nowWall.year, nowWall.month, nowWall.day);
  final dayOnly = DateTime(day.year, day.month, day.day);
  if (dayOnly.isBefore(today)) {
    issues.add(SlotIssue.inPast);
  } else if (_isSameDay(dayOnly, today)) {
    final nowHour = nowWall.hour + nowWall.minute / 60;
    if (startHour < nowHour) issues.add(SlotIssue.inPast);
  }

  final advanceLimit = today.add(Duration(days: facility.advanceBookingDays));
  if (dayOnly.isAfter(advanceLimit)) {
    issues.add(SlotIssue.beyondAdvance);
  }

  if (endHour > startHour) {
    final inflated = _inflate(busy, facility.bookingBufferMinutes);
    final clashes = inflated.any(
      (b) => b.startHour < endHour && startHour < b.endHour,
    );
    if (clashes) issues.add(SlotIssue.clash);
  }

  return SlotVerdict(issues);
}

DateTime? nextOpenDayWithSpace(
  Facility facility,
  DateTime from,
  double duration,
  Map<String, List<BusyWindow>> byDay, {
  int lookahead = 14,
}) {
  var day = DateTime(from.year, from.month, from.day);
  for (var i = 0; i < lookahead; i++) {
    if (facility.opensOn(day)) {
      final busy = byDay[dayKey(day)] ?? const [];
      final slots = freeSlotsForDay(
        facility: facility,
        day: day,
        busy: busy,
        durationHours: duration,
        limit: 1,
      );
      if (slots.isNotEmpty) return day;
    }
    day = day.add(const Duration(days: 1));
  }
  return null;
}
