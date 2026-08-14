import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_nlu.dart';

void main() {
  // A fixed "now" so date/time resolution is reproducible. Wednesday.
  final now = DateTime(2026, 8, 12, 9, 0);

  group('parseMessage — the two example phrases', () {
    test('book request with typos: capacity, amenity, and date all resolve', () {
      final p = parseMessage(
        'i want to book for 50-60 person with arcoin an and seats on auges 20',
        nowWall: now,
      );
      expect(p.intent, AssistantIntent.book);
      expect(p.capacity, isNotNull);
      expect(p.capacity!.min, 50);
      expect(p.capacity!.max, 60);
      expect(p.amenities, {'Air Conditioning'});
      expect(p.date, isNotNull);
      expect(p.date!.invalid, isFalse);
      expect(p.date!.day!.month, 8);
      expect(p.date!.day!.day, 20);
      expect(p.facilityQuery, isNull);
      expect(p.time, isNull);
    });

    test('"what are the available facilities" asks to browse, not a single slot', () {
      final p = parseMessage('what are the available facilities', nowWall: now);
      expect(p.intent, AssistantIntent.findFacilities);
      expect(p.capacity, isNull);
      expect(p.date, isNull);
      expect(p.time, isNull);
      expect(p.facilityQuery, anyOf(isNull, isEmpty));
    });
  });

  group('parseMessage — availability check', () {
    test('resolves a named facility, a future weekday, and a time range', () {
      final p = parseMessage(
        'is the auditorium free on thursday 2-4pm',
        nowWall: now,
      );
      expect(p.intent, AssistantIntent.checkAvailability);
      expect(p.facilityQuery, 'auditorium');
      expect(p.date, isNotNull);
      expect(p.date!.day!.weekday, DateTime.thursday);
      expect(p.date!.day!.isAfter(DateTime(now.year, now.month, now.day)), isTrue);
      expect(p.time, isNotNull);
      expect(p.time!.startHour, 14.0);
      expect(p.time!.endHour, 16.0);
    });
  });

  group('parseMessage — intents', () {
    test('show my reservations', () {
      final p = parseMessage('show my reservations', nowWall: now);
      expect(p.intent, AssistantIntent.myReservations);
    });

    test('cancel my booking', () {
      final p = parseMessage('cancel my booking', nowWall: now);
      expect(p.intent, AssistantIntent.cancel);
      expect(p.abort, isFalse);
    });

    test('help', () {
      final p = parseMessage('help', nowWall: now);
      expect(p.intent, AssistantIntent.help);
    });

    test('empty string is unknown, not a crash', () {
      final p = parseMessage('', nowWall: now);
      expect(p.intent, AssistantIntent.unknown);
      expect(p.hasSlots, isFalse);
    });

    test('gibberish is unknown', () {
      final p = parseMessage('asdkjhasd', nowWall: now);
      expect(p.intent, AssistantIntent.unknown);
    });

    test('bare "cancel" (no reservation context) is an abort, not a cancel-intent', () {
      final p = parseMessage('cancel', nowWall: now);
      expect(p.abort, isTrue);
    });

    test('"never mind" aborts', () {
      final p = parseMessage('never mind', nowWall: now);
      expect(p.abort, isTrue);
    });
  });

  group('parseMessage — times', () {
    test('9am to 11am', () {
      final p = parseMessage('9am to 11am', nowWall: now);
      expect(p.time!.startHour, 9.0);
      expect(p.time!.endHour, 11.0);
    });

    test('13:00-15:00 (24-hour, no meridiem)', () {
      final p = parseMessage('13:00-15:00', nowWall: now);
      expect(p.time!.startHour, 13.0);
      expect(p.time!.endHour, 15.0);
    });

    test('2pm for 2 hours', () {
      final p = parseMessage('2pm for 2 hours', nowWall: now);
      expect(p.time!.startHour, 14.0);
      expect(p.time!.endHour, 16.0);
    });

    test('at 3pm (start only, no end)', () {
      final p = parseMessage('at 3pm', nowWall: now);
      expect(p.time!.startHour, 15.0);
      expect(p.time!.endHour, isNull);
    });

    test('tomorrow afternoon resolves both a date and a named time block', () {
      final p = parseMessage('tomorrow afternoon', nowWall: now);
      expect(p.date!.day, DateTime(now.year, now.month, now.day + 1));
      expect(p.time!.startHour, 13.0);
      expect(p.time!.endHour, 15.0);
    });
  });

  group('parseMessage — dates', () {
    test('aug 20 / august 20 / auges 20 / 20 aug all resolve to Aug 20', () {
      for (final phrase in ['aug 20', 'august 20', 'auges 20', '20 aug']) {
        final p = parseMessage(phrase, nowWall: now);
        expect(p.date, isNotNull, reason: phrase);
        expect(p.date!.invalid, isFalse, reason: phrase);
        expect(p.date!.day!.month, 8, reason: phrase);
        expect(p.date!.day!.day, 20, reason: phrase);
      }
    });

    test('tomorrow / tommorow (typo) both resolve to the next day', () {
      final expected = DateTime(now.year, now.month, now.day + 1);
      for (final phrase in ['tomorrow', 'tommorow']) {
        final p = parseMessage(phrase, nowWall: now);
        expect(p.date!.day, expected, reason: phrase);
      }
    });

    test('next friday is strictly after today and in the following week', () {
      final p = parseMessage('next friday', nowWall: now);
      final today = DateTime(now.year, now.month, now.day);
      expect(p.date!.day!.weekday, DateTime.friday);
      expect(p.date!.day!.isAfter(today), isTrue);
    });

    test('monday resolves to a future Monday', () {
      final p = parseMessage('monday', nowWall: now);
      final today = DateTime(now.year, now.month, now.day);
      expect(p.date!.day!.weekday, DateTime.monday);
      expect(p.date!.day!.isAfter(today), isTrue);
    });

    test('today resolves to nowWall\'s date', () {
      final p = parseMessage('today', nowWall: now);
      expect(p.date!.day, DateTime(now.year, now.month, now.day));
    });

    test('feb 30 is flagged invalid, not silently rounded', () {
      final p = parseMessage('feb 30', nowWall: now);
      expect(p.date, isNotNull);
      expect(p.date!.invalid, isTrue);
    });
  });

  group('parseMessage — capacity', () {
    test('for 30 people -> exact 30', () {
      final p = parseMessage('for 30 people', nowWall: now);
      expect(p.capacity!.min, 30);
      expect(p.capacity!.max, 30);
    });

    test('50+ -> minimum only, no max', () {
      final p = parseMessage('50+', nowWall: now);
      expect(p.capacity!.min, 50);
      expect(p.capacity!.max, isNull);
    });

    test('30 pax -> exact 30', () {
      final p = parseMessage('30 pax', nowWall: now);
      expect(p.capacity!.min, 30);
      expect(p.capacity!.max, 30);
    });

    test('we are 12 -> exact 12', () {
      final p = parseMessage('we are 12', nowWall: now);
      expect(p.capacity!.min, 12);
      expect(p.capacity!.max, 12);
    });
  });

  group('parseMessage — amenities', () {
    test('arcoin (typo) fuzzes to Air Conditioning', () {
      final p = parseMessage('with arcoin', nowWall: now);
      expect(p.amenities, {'Air Conditioning'});
    });

    test('a/c resolves to Air Conditioning', () {
      final p = parseMessage('needs a/c', nowWall: now);
      expect(p.amenities, {'Air Conditioning'});
    });

    test('wifi resolves to Wi-Fi', () {
      final p = parseMessage('with wifi', nowWall: now);
      expect(p.amenities, {'Wi-Fi'});
    });

    test('projector resolves to Projector', () {
      final p = parseMessage('with a projector', nowWall: now);
      expect(p.amenities, {'Projector'});
    });

    test('speakers resolves to Sound System', () {
      final p = parseMessage('with speakers', nowWall: now);
      expect(p.amenities, {'Sound System'});
    });

    test('"with seats" is a capacity noun, not an amenity', () {
      final p = parseMessage('with seats', nowWall: now);
      expect(p.amenities, isEmpty);
      expect(p.unknownAmenityWords, isEmpty);
    });

    test('"with a piano" flags an unknown amenity instead of dropping it', () {
      final p = parseMessage('with a piano', nowWall: now);
      expect(p.amenities, isEmpty);
      expect(p.unknownAmenityWords, contains('piano'));
    });
  });

  group('parseMessage — three ambiguous numbers in one message', () {
    test('book 20 on 20 aug for 20 people', () {
      final p = parseMessage('book 20 on 20 aug for 20 people', nowWall: now);
      expect(p.intent, AssistantIntent.book);
      expect(p.date, isNotNull);
      expect(p.date!.invalid, isFalse);
      expect(p.date!.day!.month, 8);
      expect(p.date!.day!.day, 20);
      expect(p.capacity, isNotNull);
      expect(p.capacity!.min, 20);
      expect(p.capacity!.max, 20);
    });
  });

  group('editDistance', () {
    test('identical strings', () {
      expect(editDistance('aircon', 'aircon'), 0);
    });

    test('one substitution', () {
      expect(editDistance('tomorrow', 'tomorrow'), 0);
      expect(editDistance('tmrow', 'tomorrow', maxDistance: 5), lessThanOrEqualTo(3));
    });

    test('caps at maxDistance + 1 when the strings are very different', () {
      expect(editDistance('cat', 'auditorium', maxDistance: 2), 3);
    });

    test('arcoin vs aircon is within a length-6 threshold of 2', () {
      expect(editDistance('arcoin', 'aircon', maxDistance: 3), lessThanOrEqualTo(2));
    });
  });

  group('fuzzyWordMatches', () {
    test('exact match', () {
      expect(fuzzyWordMatches('auditorium', 'auditorium'), isTrue);
    });

    test('prefix match', () {
      expect(fuzzyWordMatches('aud', 'auditorium'), isTrue);
    });

    test('typo within threshold', () {
      expect(fuzzyWordMatches('audotorium', 'auditorium'), isTrue);
    });

    test('unrelated words do not match', () {
      expect(fuzzyWordMatches('gym', 'auditorium'), isFalse);
    });

    test('different first letter never matches', () {
      expect(fuzzyWordMatches('xuditorium', 'auditorium'), isFalse);
    });
  });
}
