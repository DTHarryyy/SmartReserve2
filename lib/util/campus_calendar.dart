library;

const campusUtcOffset = Duration(hours: 8);

DateTime campusWallTime(DateTime instant) =>
    instant.toUtc().add(campusUtcOffset);

DateTime campusInstant(DateTime wallTime) => DateTime.utc(
  wallTime.year,
  wallTime.month,
  wallTime.day,
  wallTime.hour,
  wallTime.minute,
  wallTime.second,
).subtract(campusUtcOffset);

DateTime campusNow() => campusWallTime(DateTime.now());

const campusYear = 2026;

final campusToday = DateTime(campusYear, 7, 26);

const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatStamp(DateTime value) {
  return '${value.day} ${monthNames[value.month - 1]} ${value.year}, '
      '${formatClock12(value.hour + value.minute / 60)}';
}

String formatDay(DateTime value) =>
    '${value.day} ${monthNames[value.month - 1]} ${value.year}';

DateTime? parseCampusDate(String label) {
  var day = 0;
  var month = 0;
  for (final token in label.trim().split(RegExp(r'[\s,]+'))) {
    final asNumber = int.tryParse(token);
    if (asNumber != null && asNumber >= 1 && asNumber <= 31) {
      day = asNumber;
      continue;
    }
    final index = monthNames.indexOf(token);
    if (index >= 0) month = index + 1;
  }
  if (day == 0 || month == 0) return null;
  return DateTime(campusYear, month, day);
}

String formatCampusDate(DateTime date) =>
    '${weekdayNames[date.weekday - 1]} ${date.day} '
    '${monthNames[date.month - 1]}';

/// The Monday-first, six-week range rendered by the month calendar.
(DateTime, DateTime) calendarMonthGridRange(DateTime anchor) {
  final first = DateTime(anchor.year, anchor.month);
  final start = first.subtract(Duration(days: first.weekday - 1));
  return (start, start.add(const Duration(days: 42)));
}

List<DateTime> workingWeekOf(DateTime date) {
  final monday = date.weekday > DateTime.friday
      ? date.add(Duration(days: 8 - date.weekday))
      : date.subtract(Duration(days: date.weekday - 1));
  return [for (var i = 0; i < 5; i++) monday.add(Duration(days: i))];
}

double parseClock(String clock) {
  final parts = clock.split(':');
  return (int.tryParse(parts.first) ?? 0) +
      (parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) / 60 : 0);
}

String formatClock(double hours) {
  final h = hours.floor();
  final m = ((hours - h) * 60).round();
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Formats a wall-clock value for display using a 12-hour clock.
String formatClock12(double hours) {
  final totalMinutes = (hours * 60).round();
  final normalized = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60);
  final hour24 = normalized ~/ 60;
  final minute = normalized % 60;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final suffix = hour24 < 12 ? 'AM' : 'PM';
  return '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
}

/// Compact 12-hour label for whole-hour chart and timeline axes.
String formatHour12(int hour) {
  final hour24 = ((hour % 24) + 24) % 24;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  return '$hour12 ${hour24 < 12 ? 'AM' : 'PM'}';
}

/// Converts an internal `HH:mm` clock value to its user-facing label.
String formatClockLabel(String clock) => formatClock12(parseClock(clock));

String formatClockRange(String start, String end) =>
    '${formatClockLabel(start)}–${formatClockLabel(end)}';

/// Converts a stored range such as `07:00–19:00` for display.
String formatStoredClockRange(String range) {
  final clocks = range.split(RegExp(r'\s*[–-]\s*'));
  if (clocks.length != 2 ||
      !clocks.every((clock) => RegExp(r'^\d{1,2}:\d{2}$').hasMatch(clock))) {
    return range;
  }
  return formatClockRange(clocks.first, clocks.last);
}

/// The subset of [allSlots] still bookable on [date], given the campus wall
/// clock [nowWall].
///
/// The backend rejects any reservation whose start is already in the past, so
/// today's elapsed slots are dropped and past dates yield nothing.
List<String> bookableSlots(
  List<String> allSlots,
  DateTime date,
  DateTime nowWall,
) {
  final today = DateTime(nowWall.year, nowWall.month, nowWall.day);
  final day = DateTime(date.year, date.month, date.day);
  if (day.isBefore(today)) return const [];
  if (day.isAfter(today)) return allSlots;
  final elapsed = nowWall.hour * 60 + nowWall.minute;
  return [
    for (final slot in allSlots)
      if (parseClock(slot) * 60 > elapsed) slot,
  ];
}

DateTime? atClock(DateTime? day, String clock) {
  if (day == null) return null;
  final parts = clock.split(':');
  return DateTime.utc(
    day.year,
    day.month,
    day.day,
    int.tryParse(parts.first) ?? 0,
    parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
  );
}

DateTime dayOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
