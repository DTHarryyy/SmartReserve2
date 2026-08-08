library;

const campusUtcOffset = Duration(hours: 8);

/// Converts an absolute instant into CSU Aparri wall-clock time without
/// depending on the device timezone.
DateTime campusWallTime(DateTime instant) =>
    instant.toUtc().add(campusUtcOffset);

/// Converts a CSU Aparri wall-clock value into an absolute UTC instant.
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
