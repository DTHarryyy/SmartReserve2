import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/util/campus_calendar.dart';

void main() {
  group('12-hour clock formatting', () {
    test('formats midnight, morning, noon, and evening', () {
      expect(formatClock12(0), '12:00 AM');
      expect(formatClock12(9.5), '9:30 AM');
      expect(formatClock12(12), '12:00 PM');
      expect(formatClock12(19.5), '7:30 PM');
      expect(formatHour12(19), '7 PM');
    });

    test('formats stored clock values and ranges for display', () {
      expect(formatClockLabel('13:30'), '1:30 PM');
      expect(formatClockRange('07:00', '19:00'), '7:00 AM–7:00 PM');
      expect(formatStoredClockRange('08:00–17:00'), '8:00 AM–5:00 PM');
    });
  });
}
