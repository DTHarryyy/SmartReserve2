library;

import 'dart:math' as math;

import '../../data/campus_data.dart';

enum AssistantIntent {
  findFacilities,
  checkAvailability,
  book,
  myReservations,
  cancel,
  help,
  unknown,

  // Informational intents. Each one is answerable from a single server-computed
  // record, so the assistant resolves them with rules alone and never spends a
  // model call on them.
  recommendFacility,
  reservationStatus,
  paymentBalance,
  paymentDeadline,
  permitStatus,
  permitRequirements,
  equipment,
  announcements,
  policyFaq,
}

/// Intents the assistant answers from a single rule-driven lookup.
const informationalIntents = <AssistantIntent>{
  AssistantIntent.recommendFacility,
  AssistantIntent.reservationStatus,
  AssistantIntent.paymentBalance,
  AssistantIntent.paymentDeadline,
  AssistantIntent.permitStatus,
  AssistantIntent.permitRequirements,
  AssistantIntent.equipment,
  AssistantIntent.announcements,
  AssistantIntent.policyFaq,
};

class CapacityRange {
  const CapacityRange(this.min, this.max);
  final int min;
  final int? max;

  @override
  String toString() => max == null ? '$min+' : '$min-$max';
}

class DateSlot {
  const DateSlot({this.day, this.invalid = false, required this.source});
  final DateTime? day;
  final bool invalid;
  final String source;
}

class TimeSlot {
  const TimeSlot({this.startHour, this.endHour, this.durationHours});
  final double? startHour;
  final double? endHour;
  final double? durationHours;
}

class ParsedMessage {
  const ParsedMessage({
    required this.raw,
    required this.normalized,
    required this.intent,
    this.affirmation,
    this.abort = false,
    this.recurringCue = false,
    this.capacity,
    this.amenities = const {},
    this.unknownAmenityWords = const {},
    this.category,
    this.date,
    this.time,
    this.ordinal,
    this.purpose,
    this.facilityQuery,
    this.activity,
  });

  final String raw;
  final String normalized;
  final AssistantIntent intent;
  final bool? affirmation;
  final bool abort;
  final bool recurringCue;
  final CapacityRange? capacity;
  final Set<String> amenities;
  final Set<String> unknownAmenityWords;
  final String? category;
  final DateSlot? date;
  final TimeSlot? time;
  final int? ordinal;
  final String? purpose;
  final String? facilityQuery;

  /// A sport/activity named in the message that maps to [activityCategories],
  /// e.g. "pickleball". Set even when no facility here actually hosts it --
  /// that gap is exactly what callers need to answer honestly.
  final String? activity;

  bool get hasSlots =>
      capacity != null ||
      amenities.isNotEmpty ||
      category != null ||
      (date != null && !date!.invalid) ||
      time != null ||
      (purpose != null && purpose!.isNotEmpty) ||
      (facilityQuery != null && facilityQuery!.isNotEmpty) ||
      activity != null;
}

ParsedMessage parseMessage(String raw, {required DateTime nowWall}) {
  final cappedRaw = raw.length > 500 ? raw.substring(0, 500) : raw;
  final normalized = _normalize(cappedRaw);
  final chars = normalized.split('');

  void mask(int start, int end) {
    for (var i = start; i < end && i < chars.length; i++) {
      chars[i] = ' ';
    }
  }

  final time = _extractTime(chars, mask);
  final date = _extractDate(chars, mask, nowWall);
  final capacity = _extractCapacity(chars, mask);
  final amenityResult = _extractAmenities(chars, mask);
  final category = _extractCategory(chars, mask);
  final purpose = _extractPurpose(chars, mask);
  final facilityQuery = _leftoverQuery(chars);
  final activity = matchActivity(normalized);

  final abort = _isAbort(normalized);
  final recurringCue = RegExp(
    r'\b(every|weekly|recurring|each week|repeat(?:ed|edly)?)\b',
  ).hasMatch(normalized);
  final affirmation = _detectAffirmation(normalized);
  final ordinal = _extractOrdinal(normalized);
  final intent = _detectIntent(
    normalized,
    capacity: capacity,
    date: date,
    time: time,
    facilityQuery: facilityQuery,
    category: category,
  );

  return ParsedMessage(
    raw: cappedRaw,
    normalized: normalized,
    intent: intent,
    affirmation: affirmation,
    abort: abort,
    recurringCue: recurringCue,
    capacity: capacity,
    amenities: amenityResult.amenities,
    unknownAmenityWords: amenityResult.unknown,
    category: category,
    date: date,
    time: time,
    ordinal: ordinal,
    purpose: purpose,
    facilityQuery: facilityQuery,
    activity: activity,
  );
}

String _normalize(String raw) {
  var s = raw.toLowerCase();
  s = s.replaceAll(RegExp('[‐-―]'), '-');
  s = s.replaceAll(RegExp(r"[^a-z0-9\s\-:/+.]"), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

const _stopwords = <String>{
  'i',
  'me',
  'my',
  'mine',
  'our',
  'ours',
  'we',
  'you',
  'your',
  'it',
  'this',
  'that',
  'these',
  'those',
  'a',
  'an',
  'the',
  'to',
  'of',
  'in',
  'on',
  'at',
  'for',
  'with',
  'and',
  'or',
  'but',
  'if',
  'so',
  'not',
  'is',
  'are',
  'was',
  'were',
  'be',
  'been',
  'being',
  'do',
  'does',
  'did',
  'will',
  'would',
  'can',
  'could',
  'should',
  'have',
  'has',
  'having',
  'had',
  'need',
  'needs',
  'needed',
  'want',
  'wants',
  'wanted',
  'like',
  'get',
  'gets',
  'got',
  'please',
  'looking',
  'look',
  'show',
  'tell',
  'give',
  'what',
  'which',
  'who',
  'when',
  'where',
  'how',
  'why',
  'any',
  'some',
  'all',
  'many',
  'much',
  'still',
  'just',
  'okay',
  'ok',
  'yes',
  'no',
  'next',
  'coming',
  'book',
  'booking',
  'bookings',
  'reserve',
  'reserving',
  'reservation',
  'reservations',
  'request',
  'requests',
  'requested',
  'cancel',
  'cancelled',
  'cancelling',
  'room',
  'rooms',
  'facility',
  'facilities',
  'venue',
  'venues',
  'space',
  'spaces',
  'place',
  'places',
  'available',
  'availability',
  'free',
  'open',
  'vacant',
  'schedule',
  'scheduled',
  'week',
  'day',
  'days',
  'date',
  'time',
  'times',
  'hour',
  'hours',
  'up',
  'from',
  'till',
  'until',
  'thru',
  'about',
  'around',
  'there',
  'here',
  'specific',
  'particular',
  // Verbs and nouns that belong to the informational intents. Without these,
  // the leftover-query extractor hands words like "pay" to facility matching.
  'status',
  'permit',
  'permits',
  'payment',
  'payments',
  'pay',
  'paid',
  'owe',
  'balance',
  'deadline',
  'due',
  'download',
  'recommend',
  'suggest',
  'equipment',
  'announcement',
  'announcements',
  'rule',
  'rules',
  'policy',
  'requirement',
  'requirements',
};

const _capacityNounWords = <String>{
  'pax',
  'person',
  'persons',
  'people',
  'ppl',
  'head',
  'heads',
  'seat',
  'seats',
  'chair',
  'chairs',
  'slot',
  'slots',
  'capacity',
  'student',
  'students',
  'attendee',
  'attendees',
};

const _capacityNounPattern =
    r'pax|persons?|people|ppl|heads?|seats?|chairs?|slots?|capacity|students?|attendees?';

const Map<String, String> _amenitySynonyms = {
  'air conditioning': 'Air Conditioning',
  'airconditioning': 'Air Conditioning',
  'air con': 'Air Conditioning',
  'aircon': 'Air Conditioning',
  'aircondition': 'Air Conditioning',
  'ac': 'Air Conditioning',
  'cooled': 'Air Conditioning',
  'wi-fi': 'Wi-Fi',
  'wifi': 'Wi-Fi',
  'internet': 'Wi-Fi',
  'wireless': 'Wi-Fi',
  'lcd projector': 'Projector',
  'projector': 'Projector',
  'beamer': 'Projector',
  'lcd': 'Projector',
  'smart tv': 'Smart TV',
  'television': 'Smart TV',
  'flat screen': 'Smart TV',
  'tv': 'Smart TV',
  'sound system': 'Sound System',
  'pa system': 'Sound System',
  'speakers': 'Sound System',
  'speaker': 'Sound System',
  'audio': 'Sound System',
  'microphone': 'Sound System',
  'mic': 'Sound System',
  'sound': 'Sound System',
  'pa': 'Sound System',
  'white board': 'Whiteboard',
  'whiteboard': 'Whiteboard',
  'board': 'Whiteboard',
  'car park': 'Parking',
  'parking': 'Parking',
  'park': 'Parking',
  'pwd accessibility': 'PWD Accessibility',
  'wheelchair': 'PWD Accessibility',
  'accessible': 'PWD Accessibility',
  'ramp': 'PWD Accessibility',
  'pwd': 'PWD Accessibility',
  'security cameras': 'Security Cameras',
  'security camera': 'Security Cameras',
  'cameras': 'Security Cameras',
  'camera': 'Security Cameras',
  'cctv': 'Security Cameras',
  'backup power': 'Generator',
  'generator': 'Generator',
  'genset': 'Generator',
  'power outlets': 'Power Outlets',
  'power outlet': 'Power Outlets',
  'outlets': 'Power Outlets',
  'outlet': 'Power Outlets',
  'sockets': 'Power Outlets',
  'socket': 'Power Outlets',
  'charging': 'Power Outlets',
  'plugs': 'Power Outlets',
  'plug': 'Power Outlets',
  'power': 'Power Outlets',
};

List<String> get knownAmenityLabels => standardAmenityLabels;

const Map<String, String> _categorySynonyms = {
  'gym': 'Gymnasium',
  'court': 'Gymnasium',
  'gymnasium': 'Gymnasium',
  'auditorium': 'Auditorium',
  'conference room': 'Conference Room',
  'conference': 'Conference Room',
  'meeting room': 'Conference Room',
  'board room': 'Conference Room',
  'boardroom': 'Conference Room',
  'library': 'Library Space',
  'library space': 'Library Space',
  'computer lab': 'Computer Laboratory',
  'computer laboratory': 'Computer Laboratory',
  'comlab': 'Computer Laboratory',
  'com lab': 'Computer Laboratory',
  'ict lab': 'Computer Laboratory',
  'science lab': 'Science Laboratory',
  'science laboratory': 'Science Laboratory',
  'wet lab': 'Science Laboratory',
  'function hall': 'Function Hall',
  'hall': 'Function Hall',
  'field': 'Outdoor Area',
  'grounds': 'Outdoor Area',
  'quadrangle': 'Outdoor Area',
  'outdoor area': 'Outdoor Area',
  'outdoor': 'Outdoor Area',
  'office': 'Office',
  'classroom': 'Classroom',
};

/// Activities campus has no dedicated facility for, mapped to the categories
/// that can actually host them.
///
/// Used only to choose and phrase ALTERNATIVES, never as a hard filter: a
/// request for an activity we cannot host has to be answered honestly, not
/// silently narrowed to something that merely shares a category.
///
/// This is the OFFLINE half of that judgement. Online, the model reads the
/// closed category list off a tool result and maps any wording at all onto
/// it, which is the only approach that can cover words nobody wrote down
/// here. This map is what still answers when the model is disabled, rate
/// limited or down -- so it is kept broad enough to be useful and is not
/// mistaken for the intelligence layer.
const Map<String, Set<String>> activityCategories = {
  // Sport. No dedicated court exists for any of these.
  'pickleball': {'Gymnasium', 'Outdoor Area'},
  'badminton': {'Gymnasium'},
  'volleyball': {'Gymnasium', 'Outdoor Area'},
  'basketball': {'Gymnasium', 'Outdoor Area'},
  'tennis': {'Outdoor Area'},
  'futsal': {'Gymnasium', 'Outdoor Area'},
  'zumba': {'Gymnasium', 'Function Hall'},
  // Academic and campus events, which are the bulk of real bookings.
  'seminar': {'Auditorium', 'Function Hall', 'Conference Room'},
  'orientation': {'Auditorium', 'Function Hall'},
  'graduation': {'Gymnasium', 'Auditorium', 'Function Hall'},
  'training': {'Conference Room', 'Classroom', 'Computer Laboratory'},
  'workshop': {'Conference Room', 'Classroom'},
  'defense': {'Conference Room', 'Classroom'},
  'pageant': {'Auditorium', 'Function Hall', 'Gymnasium'},
  'esports': {'Computer Laboratory'},
  'jobfair': {'Gymnasium', 'Function Hall'},
};

/// The activity named in a message, if any.
///
/// Adjacent words are joined before testing so "pickle ball" resolves the same
/// as "pickleball", and [fuzzyWordMatches] covers the near-misses people
/// actually type. Read from the NORMALIZED message rather than the masked
/// buffer, so the activity survives whichever extractor consumed the words.
String? matchActivity(String normalized) {
  final words = RegExp(
    r'[a-z]+',
  ).allMatches(normalized).map((m) => m.group(0)!).toList();
  for (var i = 0; i < words.length; i++) {
    final single = words[i];
    final pair = i + 1 < words.length ? '$single${words[i + 1]}' : null;
    for (final key in activityCategories.keys) {
      if (single == key || pair == key) return key;
      // fuzzyWordMatches' prefix branch only requires 3 characters, which
      // would let "ten" match "tennis". Every activity key here is at least
      // five letters, so a word of four or more can only be a real typo,
      // never a genuine abbreviation of one of them.
      if (single.length >= 4 && fuzzyWordMatches(single, key)) return key;
      if (pair != null && fuzzyWordMatches(pair, key)) return key;
    }
  }
  return null;
}

const _monthAbbrev = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];
const _monthFull = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];
const _weekdayAbbrev = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const _weekdayFull = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

int editDistance(String a, String b, {int maxDistance = 2}) {
  if (a == b) return 0;
  final lenDiff = (a.length - b.length).abs();
  if (lenDiff > maxDistance) return maxDistance + 1;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prev = List<int>.generate(b.length + 1, (j) => j);
  var curr = List<int>.filled(b.length + 1, 0);

  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    var rowMin = curr[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
      if (curr[j] < rowMin) rowMin = curr[j];
    }
    if (rowMin > maxDistance) return maxDistance + 1;
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length] <= maxDistance ? prev[b.length] : maxDistance + 1;
}

bool fuzzyWordMatches(String token, String candidate) {
  if (token == candidate) return true;
  if (token.length >= 3 && candidate.startsWith(token)) return true;
  if (token.isEmpty || candidate.isEmpty || token[0] != candidate[0]) {
    return false;
  }
  if (token.length < 4) return false;
  final threshold = token.length >= 6 ? 2 : 1;
  return editDistance(token, candidate, maxDistance: threshold + 1) <=
      threshold;
}

final _timeRangeRe = RegExp(
  r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|to|till|until|thru)\s*'
  r'(\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
);
final _timeStartDurationRe = RegExp(
  r'(?:at|from)?\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*for\s*'
  r'(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h)\b',
);
final _timeStartOnlyRe = RegExp(
  r'\b(?:at|around)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
);
final _namedBlockRe = RegExp(r'\b(morning|afternoon|evening)\b');

bool _validHour(int h, {required bool hasMeridiem}) =>
    hasMeridiem ? (h >= 1 && h <= 12) : (h >= 0 && h <= 23);

int _to24(int h, String? meridiem) {
  if (meridiem == 'pm') return h == 12 ? 12 : h + 12;
  if (meridiem == 'am') return h == 12 ? 0 : h;
  return h;
}

double _snapStart(double h) => (h * 2).floor() / 2;
double _snapEnd(double h) => (h * 2).ceil() / 2;

TimeSlot? _extractTime(List<String> chars, void Function(int, int) mask) {
  final text = chars.join();

  Match? best;
  for (final m in _timeRangeRe.allMatches(text)) {
    final h1 = int.parse(m.group(1)!);
    final h2 = int.parse(m.group(4)!);
    if (_validHour(h1, hasMeridiem: m.group(3) != null) &&
        _validHour(h2, hasMeridiem: m.group(6) != null)) {
      best = m;
      break;
    }
  }
  if (best != null) {
    final h1 = int.parse(best.group(1)!);
    final min1 = best.group(2) != null ? int.parse(best.group(2)!) : 0;
    final mer1 = best.group(3);
    final h2 = int.parse(best.group(4)!);
    final min2 = best.group(5) != null ? int.parse(best.group(5)!) : 0;
    final mer2 = best.group(6);

    var start24 = _to24(h1, mer1);
    var end24 = _to24(h2, mer2);

    if (mer1 == null && mer2 != null) {
      final inferred = _to24(h1, mer2);
      start24 = inferred < end24 ? inferred : _to24(h1, 'am');
    } else if (mer1 != null && mer2 == null) {
      final inferred = _to24(h2, mer1);
      end24 = inferred > start24
          ? inferred
          : _to24(h2, mer1 == 'pm' ? 'am' : 'pm');
    } else if (mer1 == null && mer2 == null) {
      start24 = h1 < 7 ? h1 + 12 : h1;
      end24 = h2 < 7 ? h2 + 12 : h2;
    }

    final startHour = _snapStart(start24 + min1 / 60);
    final endHour = _snapEnd(end24 + min2 / 60);
    if (endHour > startHour) {
      mask(best.start, best.end);
      return TimeSlot(
        startHour: startHour,
        endHour: endHour,
        durationHours: endHour - startHour,
      );
    }
  }

  final durationMatch = _timeStartDurationRe.firstMatch(text);
  if (durationMatch != null) {
    final h = int.parse(durationMatch.group(1)!);
    final min = durationMatch.group(2) != null
        ? int.parse(durationMatch.group(2)!)
        : 0;
    final mer = durationMatch.group(3);
    if (_validHour(h, hasMeridiem: mer != null)) {
      final start24 = mer != null ? _to24(h, mer) : (h < 7 ? h + 12 : h);
      final duration = double.parse(durationMatch.group(4)!);
      if (duration > 0 && duration <= 12) {
        final startHour = _snapStart(start24 + min / 60);
        final endHour = _snapEnd(startHour + duration);
        mask(durationMatch.start, durationMatch.end);
        return TimeSlot(
          startHour: startHour,
          endHour: endHour,
          durationHours: endHour - startHour,
        );
      }
    }
  }

  final startOnlyMatch = _timeStartOnlyRe.firstMatch(text);
  if (startOnlyMatch != null) {
    final h = int.parse(startOnlyMatch.group(1)!);
    final min = startOnlyMatch.group(2) != null
        ? int.parse(startOnlyMatch.group(2)!)
        : 0;
    final mer = startOnlyMatch.group(3);
    if (_validHour(h, hasMeridiem: mer != null)) {
      final start24 = mer != null ? _to24(h, mer) : (h < 7 ? h + 12 : h);
      final startHour = _snapStart(start24 + min / 60);
      mask(startOnlyMatch.start, startOnlyMatch.end);
      return TimeSlot(startHour: startHour, endHour: null, durationHours: null);
    }
  }

  final namedMatch = _namedBlockRe.firstMatch(text);
  if (namedMatch != null) {
    final block = namedMatch.group(1)!;
    final range = switch (block) {
      'morning' => (8.0, 10.0),
      'afternoon' => (13.0, 15.0),
      _ => (17.0, 19.0),
    };
    mask(namedMatch.start, namedMatch.end);
    return TimeSlot(
      startHour: range.$1,
      endHour: range.$2,
      durationHours: range.$2 - range.$1,
    );
  }

  return null;
}

final _numericDateRe = RegExp(r'\b(\d{1,2})/(\d{1,2})\b');

int? _matchMonth(String token) {
  if (token.length < 3) return null;
  for (var i = 0; i < 12; i++) {
    if (token == _monthAbbrev[i] || token == _monthFull[i]) return i + 1;
  }
  for (var i = 0; i < 12; i++) {
    if (_monthFull[i].startsWith(token)) return i + 1;
  }
  var best = -1;
  var bestDist = 999;
  var ties = 0;
  for (var i = 0; i < 12; i++) {
    final threshold = token.length >= 5 ? 2 : 1;
    final d = editDistance(token, _monthFull[i], maxDistance: 3);
    if (d <= threshold) {
      if (d < bestDist) {
        bestDist = d;
        best = i;
        ties = 1;
      } else if (d == bestDist) {
        ties++;
      }
    }
  }
  return (best >= 0 && ties == 1) ? best + 1 : null;
}

int? _matchWeekday(String token) {
  if (token.length < 3) return null;
  for (var i = 0; i < 7; i++) {
    if (token == _weekdayAbbrev[i] || token == _weekdayFull[i]) return i + 1;
  }
  for (var i = 0; i < 7; i++) {
    if (_weekdayFull[i].startsWith(token)) return i + 1;
  }
  var best = -1;
  var bestDist = 999;
  var ties = 0;
  for (var i = 0; i < 7; i++) {
    final threshold = token.length >= 6 ? 2 : 1;
    final d = editDistance(token, _weekdayFull[i], maxDistance: 3);
    if (d <= threshold) {
      if (d < bestDist) {
        bestDist = d;
        best = i;
        ties = 1;
      } else if (d == bestDist) {
        ties++;
      }
    }
  }
  return (best >= 0 && ties == 1) ? best + 1 : null;
}

DateTime _resolveWeekday(
  int isoWeekday,
  DateTime today, {
  required bool nextModifier,
}) {
  var delta = (isoWeekday - today.weekday) % 7;
  if (delta < 0) delta += 7;
  if (delta == 0) delta = 7;
  var result = today.add(Duration(days: delta));
  if (nextModifier) {
    final todayMonday = today.subtract(Duration(days: today.weekday - 1));
    final resultMonday = result.subtract(Duration(days: result.weekday - 1));
    if (resultMonday == todayMonday) {
      result = result.add(const Duration(days: 7));
    }
  }
  return result;
}

DateSlot? _extractWeekday(
  String text,
  DateTime today,
  void Function(int, int) mask,
) {
  final wordRe = RegExp(r'\b[a-z]{3,9}\b');
  for (final m in wordRe.allMatches(text)) {
    final word = m.group(0)!;
    final iso = _matchWeekday(word);
    if (iso == null) continue;
    final windowStart = math.max(0, m.start - 12);
    final before = text.substring(windowStart, m.start);
    final modMatch = RegExp(r'\b(next|this|coming|on)\s+$').firstMatch(before);
    final nextModifier = modMatch != null && modMatch.group(1) == 'next';
    final resolved = _resolveWeekday(iso, today, nextModifier: nextModifier);
    final start = modMatch != null ? windowStart + modMatch.start : m.start;
    mask(start, m.end);
    return DateSlot(day: resolved, source: word);
  }
  return null;
}

DateSlot? _extractMonthDay(
  String text,
  DateTime nowWall,
  void Function(int, int) mask,
) {
  final wordRe = RegExp(r'\b[a-z]{3,9}\b');
  Match? monthMatch;
  for (final m in wordRe.allMatches(text)) {
    if (_matchMonth(m.group(0)!) != null) {
      monthMatch = m;
      break;
    }
  }
  if (monthMatch == null) return null;
  final month = _matchMonth(monthMatch.group(0)!)!;

  final afterWindowEnd = math.min(text.length, monthMatch.end + 6);
  final after = text.substring(monthMatch.end, afterWindowEnd);
  final afterMatch = RegExp(
    r'^\s*(\d{1,2})(?:st|nd|rd|th)?\b',
  ).firstMatch(after);

  final beforeWindowStart = math.max(0, monthMatch.start - 6);
  final before = text.substring(beforeWindowStart, monthMatch.start);
  final beforeMatch = RegExp(
    r'(\d{1,2})(?:st|nd|rd|th)?\s*$',
  ).firstMatch(before);

  int? day;
  var spanStart = monthMatch.start;
  var spanEnd = monthMatch.end;
  if (afterMatch != null) {
    day = int.parse(afterMatch.group(1)!);
    spanEnd = monthMatch.end + afterMatch.end;
  } else if (beforeMatch != null) {
    day = int.parse(beforeMatch.group(1)!);
    spanStart = beforeWindowStart + beforeMatch.start;
  }
  if (day == null) return null;

  mask(spanStart, spanEnd);
  if (day < 1 || day > 31) {
    return const DateSlot(invalid: true, source: 'month-day');
  }
  final year = nowWall.year;
  var candidate = DateTime(year, month, day);
  if (candidate.month != month || candidate.day != day) {
    return const DateSlot(invalid: true, source: 'month-day');
  }
  final today = DateTime(nowWall.year, nowWall.month, nowWall.day);
  if (candidate.isBefore(today)) candidate = DateTime(year + 1, month, day);
  return DateSlot(day: candidate, source: 'month-day');
}

DateSlot? _extractDate(
  List<String> chars,
  void Function(int, int) mask,
  DateTime nowWall,
) {
  final text = chars.join();
  final today = DateTime(nowWall.year, nowWall.month, nowWall.day);

  final dayAfterMatch = RegExp(r'\bday after tomorrow\b').firstMatch(text);
  if (dayAfterMatch != null) {
    mask(dayAfterMatch.start, dayAfterMatch.end);
    return DateSlot(
      day: today.add(const Duration(days: 2)),
      source: 'day after tomorrow',
    );
  }
  final nextWeekMatch = RegExp(r'\bnext week\b').firstMatch(text);
  if (nextWeekMatch != null) {
    mask(nextWeekMatch.start, nextWeekMatch.end);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    return DateSlot(
      day: monday.add(const Duration(days: 7)),
      source: 'next week',
    );
  }
  final tomorrowMatch = RegExp(
    r'\b(tomorrow|tommorow|tmrw|tmr)\b',
  ).firstMatch(text);
  if (tomorrowMatch != null) {
    mask(tomorrowMatch.start, tomorrowMatch.end);
    return DateSlot(
      day: today.add(const Duration(days: 1)),
      source: 'tomorrow',
    );
  }
  final todayMatch = RegExp(r'\b(today|tonight)\b').firstMatch(text);
  if (todayMatch != null) {
    mask(todayMatch.start, todayMatch.end);
    return DateSlot(day: today, source: 'today');
  }

  final weekdayResult = _extractWeekday(text, today, mask);
  if (weekdayResult != null) return weekdayResult;

  final monthDayResult = _extractMonthDay(text, nowWall, mask);
  if (monthDayResult != null) return monthDayResult;

  final numericMatch = _numericDateRe.firstMatch(text);
  if (numericMatch != null) {
    final d = int.parse(numericMatch.group(1)!);
    final m = int.parse(numericMatch.group(2)!);
    mask(numericMatch.start, numericMatch.end);
    if (m < 1 || m > 12 || d < 1 || d > 31) {
      return const DateSlot(invalid: true, source: 'numeric');
    }
    final year = nowWall.year;
    var candidate = DateTime(year, m, d);
    if (candidate.month != m || candidate.day != d) {
      return const DateSlot(invalid: true, source: 'numeric');
    }
    if (candidate.isBefore(today)) candidate = DateTime(year + 1, m, d);
    return DateSlot(day: candidate, source: 'numeric');
  }

  return null;
}

final _capacityRangeRe = RegExp(
  '(\\d{1,4})\\s*(?:-|to)\\s*(\\d{1,4})\\s*(?:$_capacityNounPattern)?',
);
final _capacityMinPlusRe = RegExp(r'(\d{1,4})\s*\+');
final _capacityForRe = RegExp(
  r'\b(?:for|about|around|approx\.?|roughly)\s+(\d{1,4})\b',
);
final _capacityWeAreRe = RegExp(r'\bwe are\s+(\d{1,4})\b');
final _capacityOfUsRe = RegExp(r'\b(\d{1,4})\s+of us\b');
final _capacityNounRe = RegExp('(\\d{1,4})\\s*(?:$_capacityNounPattern)\\b');

bool _validCapacity(int n) => n >= 1 && n <= 5000;

CapacityRange? _extractCapacity(
  List<String> chars,
  void Function(int, int) mask,
) {
  final text = chars.join();

  final rangeMatch = _capacityRangeRe.firstMatch(text);
  if (rangeMatch != null) {
    final lo = int.parse(rangeMatch.group(1)!);
    final hi = int.parse(rangeMatch.group(2)!);
    if (_validCapacity(lo) && _validCapacity(hi)) {
      mask(rangeMatch.start, rangeMatch.end);
      return CapacityRange(math.min(lo, hi), math.max(lo, hi));
    }
  }

  final plusMatch = _capacityMinPlusRe.firstMatch(text);
  if (plusMatch != null) {
    final lo = int.parse(plusMatch.group(1)!);
    if (_validCapacity(lo)) {
      mask(plusMatch.start, plusMatch.end);
      return CapacityRange(lo, null);
    }
  }

  final forMatch = _capacityForRe.firstMatch(text);
  if (forMatch != null) {
    final n = int.parse(forMatch.group(1)!);
    if (_validCapacity(n)) {
      mask(forMatch.start, forMatch.end);
      return CapacityRange(n, n);
    }
  }

  final weAreMatch =
      _capacityWeAreRe.firstMatch(text) ?? _capacityOfUsRe.firstMatch(text);
  if (weAreMatch != null) {
    final n = int.parse(weAreMatch.group(1)!);
    if (_validCapacity(n)) {
      mask(weAreMatch.start, weAreMatch.end);
      return CapacityRange(n, n);
    }
  }

  final nounMatch = _capacityNounRe.firstMatch(text);
  if (nounMatch != null) {
    final n = int.parse(nounMatch.group(1)!);
    if (_validCapacity(n)) {
      mask(nounMatch.start, nounMatch.end);
      return CapacityRange(n, n);
    }
  }

  return null;
}

class _AmenityResult {
  _AmenityResult(this.amenities, this.unknown);
  final Set<String> amenities;
  final Set<String> unknown;
}

final _acPatternRe = RegExp(r'\ba[/-]c\b');
final _cueWordRe = RegExp(
  r'\b(?:with|has|have|having|need|needs|w)\s+(?:(?:a|an|the)\s+)?([a-z][a-z\-]*)',
);
final _bareWordRe = RegExp(r'\b[a-z]{2,}\b');

String? _resolveAmenityWord(String word) {
  if (_amenitySynonyms.containsKey(word)) return _amenitySynonyms[word];
  if (word.length < 4) return null;
  String? best;
  var bestDist = 999;
  var ties = 0;
  for (final entry in _amenitySynonyms.entries) {
    if (entry.key.contains(' ')) continue;
    if (entry.key.isEmpty || entry.key[0] != word[0]) continue;
    final threshold = word.length >= 6 ? 2 : 1;
    final d = editDistance(word, entry.key, maxDistance: 3);
    if (d <= threshold) {
      if (d < bestDist) {
        bestDist = d;
        best = entry.value;
        ties = 1;
      } else if (d == bestDist && entry.value != best) {
        ties++;
      }
    }
  }
  return ties == 1 ? best : null;
}

_AmenityResult _extractAmenities(
  List<String> chars,
  void Function(int, int) mask,
) {
  final amenities = <String>{};
  final unknown = <String>{};

  final acMatch = _acPatternRe.firstMatch(chars.join());
  if (acMatch != null) {
    amenities.add('Air Conditioning');
    mask(acMatch.start, acMatch.end);
  }

  final multiKeys = _amenitySynonyms.keys.where((k) => k.contains(' ')).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final key in multiKeys) {
    while (true) {
      final text = chars.join();
      final m = RegExp(r'\b' + RegExp.escape(key) + r'\b').firstMatch(text);
      if (m == null) break;
      amenities.add(_amenitySynonyms[key]!);
      mask(m.start, m.end);
    }
  }

  {
    final text = chars.join();
    for (final m in _cueWordRe.allMatches(text)) {
      final word = m.group(1)!;
      if (word.isEmpty) continue;
      final canonical = _resolveAmenityWord(word);
      if (canonical != null) {
        amenities.add(canonical);
        mask(m.start, m.end);
      } else if (!_stopwords.contains(word) &&
          !_capacityNounWords.contains(word) &&
          word.length >= 3) {
        unknown.add(word);
        mask(m.start, m.end);
      }
    }
  }

  {
    final text = chars.join();
    for (final m in _bareWordRe.allMatches(text)) {
      final word = m.group(0)!;
      final canonical = _resolveAmenityWord(word);
      if (canonical != null) {
        amenities.add(canonical);
        mask(m.start, m.end);
      }
    }
  }

  return _AmenityResult(amenities, unknown);
}

String? _extractCategory(List<String> chars, void Function(int, int) mask) {
  final keys = _categorySynonyms.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final text = chars.join();
  for (final key in keys) {
    final m = RegExp(r'\b' + RegExp.escape(key) + r'\b').firstMatch(text);
    if (m != null) {
      return _categorySynonyms[key];
    }
  }
  return null;
}

final _purposeRe = RegExp(
  r'\bfor\s+(?:a|an|our|my|the)\s+([a-z][a-z\- ]{2,80})',
);

const _facilityNouns = {
  'court',
  'room',
  'hall',
  'gym',
  'gymnasium',
  'field',
  'space',
  'venue',
  'area',
  'lab',
  'laboratory',
  'grounds',
};

/// True when a "for a ..." phrase is naming the thing being booked rather
/// than why it is being booked.
bool _describesAFacility(String phrase) {
  if (matchActivity(phrase) != null) return true;
  final words = RegExp(
    r'[a-z]+',
  ).allMatches(phrase).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return false;
  if (_facilityNouns.contains(words.first)) return true;
  return _categorySynonyms.keys.any(phrase.startsWith);
}

String? _extractPurpose(List<String> chars, void Function(int, int) mask) {
  final text = chars.join();
  final match = _purposeRe.firstMatch(text);
  if (match == null) return null;
  final phrase = match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (phrase.length < 3) return null;
  // "for a court we can play pickle ball" describes the FACILITY, not the
  // purpose. Returning WITHOUT masking leaves those words in the buffer for
  // _leftoverQuery, so they can still be matched against the catalogue -- and
  // keeps them out of draft.purpose, which is submitted verbatim.
  if (_describesAFacility(phrase)) return null;
  mask(match.start, match.end);
  return phrase;
}

String? _leftoverQuery(List<String> chars) {
  final text = chars.join();
  final words = RegExp(
    r'[a-z][a-z\-]*',
  ).allMatches(text).map((m) => m.group(0)!);
  final kept = <String>[];
  for (final w in words) {
    if (w.length < 3) continue;
    if (_stopwords.contains(w)) continue;
    if (_capacityNounWords.contains(w)) continue;
    kept.add(w);
  }
  if (kept.isEmpty) return null;
  return kept.join(' ');
}

final _mineReservationRe = RegExp(
  r'\b(my|mine)\b.{0,15}\b(reservation|reservations|booking|bookings|request|requests)\b',
);

// Filipino puts the possessive after the noun -- "reservation ko", "bayad ko".
// Treated as equivalent to "my reservation" so Taglish questions resolve on the
// free path instead of escalating.
final _taglishMineRe = RegExp(
  r'\b(reservation|reservations|booking|bookings|request|requests|permit|permiso|'
  r'bayad|balance|utang|schedule)\s+(ko|namin|amin)\b',
);

/// True when the message is about the speaker's own records, in either
/// language.
bool _isFirstPersonRecord(String normalized) =>
    _mineReservationRe.hasMatch(normalized) ||
    _taglishMineRe.hasMatch(normalized) ||
    RegExp(r'\b(do|did|am|can)\s+i\b').hasMatch(normalized) ||
    RegExp(r'\bi\s+(owe|still|have|need)\b').hasMatch(normalized);

// "When is it due" must win over "how much", so deadline is tested first.
final _paymentDeadlineRe = RegExp(
  r'\b(deadline|due date|overdue)\b|'
  r'\bwhen\b.{0,25}\b(due|pay|payment|bayad)\b|'
  r'\bkailan\b.{0,25}\b(bayad|due|deadline)\b',
);

final _paymentBalanceRe = RegExp(
  r'\bmagkano\b|\butang\b|'
  r'\b(outstanding|balance|down ?payment|downpayment)\b|'
  r'\bhow much\b|'
  r'\b(still|need to|have to|must)\s+pay\b|'
  r'\b(i|we)\s+owe\b|'
  r'\bbayad(an)?\s+(ko|pa|namin)\b',
);

final _permitRe = RegExp(r'\bpermits?\b|\bpermiso\b');

final _permitRequirementsRe = RegExp(
  r'\b(requirement|requirements|need|needed|kailangan|before)\b',
);

final _statusRe = RegExp(
  r'\b(status|approved|approve|declined|decline|rejected|pending|confirmed|'
  r'accepted|na-?approve|aprub|kumusta|ano na)\b',
);

final _equipmentRe = RegExp(
  r'\b(equipment|equipments|kagamitan|amenity|amenities|gamit)\b',
);

final _announcementRe = RegExp(
  r'\b(announcement|announcements|notice|notices|notification|notifications|'
  r'balita|advisory|advisories)\b',
);

final _policyRe = RegExp(
  r'\b(rule|rules|policy|policies|requirement|requirements|guideline|'
  r'guidelines|patakaran|terms|allowed|entitled)\b',
);

// Deliberately only explicit recommendation verbs. Softer cues like "best" or
// "good for" appear constantly in ordinary booking talk ("what's the best time
// to book the gym") and would steal turns the booking flow should own.
final _recommendRe = RegExp(
  r'\b(recommend|recommendation|recommendations|suggest|suggestions|suggested|'
  r'imungkahi|mungkahi)\b|\bsuggestion\b',
);

final _mineAnyRe = RegExp(r'\b(my|mine|akin|amin)\b');

bool _isAbort(String normalized) {
  if (_mineReservationRe.hasMatch(normalized) &&
      normalized.contains('cancel')) {
    return false;
  }
  if (RegExp(
    r'\b(stop|never ?mind|start over|forget it|reset|abort)\b',
  ).hasMatch(normalized)) {
    return true;
  }
  return RegExp(r'^\s*cancel\s*$').hasMatch(normalized);
}

bool? _detectAffirmation(String normalized) {
  if (RegExp(
    r'^(yes|yeah|yep|sure|ok|okay|confirm|correct|right|go ahead)\b',
  ).hasMatch(normalized)) {
    return true;
  }
  if (RegExp(r'^(no|nope|nah|wrong)\b').hasMatch(normalized)) {
    return false;
  }
  return null;
}

int? _extractOrdinal(String normalized) {
  const words = {'first': 1, 'second': 2, 'third': 3, 'fourth': 4, 'fifth': 5};
  final wordMatch = RegExp(
    r'\b(first|second|third|fourth|fifth)\b',
  ).firstMatch(normalized);
  if (wordMatch != null) return words[wordMatch.group(1)];
  final numMatch = RegExp(r'\b(\d)(?:st|nd|rd|th)\b').firstMatch(normalized);
  if (numMatch != null) return int.tryParse(numMatch.group(1)!);
  final optionMatch = RegExp(r'\boption\s+(\d)\b').firstMatch(normalized);
  if (optionMatch != null) return int.tryParse(optionMatch.group(1)!);
  return null;
}

AssistantIntent _detectIntent(
  String normalized, {
  required CapacityRange? capacity,
  required DateSlot? date,
  required TimeSlot? time,
  required String? facilityQuery,
  required String? category,
}) {
  final hasCancel = RegExp(
    r'\bcancel\b|\bkansela\b|\bkanselahin\b',
  ).hasMatch(normalized);
  final hasMine = _mineReservationRe.hasMatch(normalized);
  final firstPerson = _isFirstPersonRecord(normalized);
  final hasHelp = RegExp(
    r'\b(help|what can you do|options|commands|tulong|ano ang kaya mo)\b',
  ).hasMatch(normalized);
  final hasBookCue = RegExp(
    r'\b(book|reserve|reservation|reserving|schedule)\b',
  ).hasMatch(normalized);
  final hasAvailableCue = RegExp(
    r'\b(available|availability|free|open|vacant|bakante|libre)\b',
  ).hasMatch(normalized);
  final hasPluralVenueWord = RegExp(
    r'\b(facilities|rooms|venues|spaces)\b',
  ).hasMatch(normalized);
  final hasListCue = RegExp(r'\b(what|which|show|list)\b').hasMatch(normalized);

  final mentionsMine =
      hasMine || _mineAnyRe.hasMatch(normalized) || firstPerson;
  final hasReservationNoun = RegExp(
    r'\b(reservation|reservations|booking|bookings|request|requests)\b',
  ).hasMatch(normalized);
  // English puts the possessive before the noun, but plenty of real questions
  // drop it entirely -- "what reservations do I have". First person plus a
  // reservation noun means the same thing.
  final aboutMyRecords =
      hasMine || (firstPerson && hasReservationNoun);

  // Any surviving "cancel" is a cancellation request: `_isAbort` has already
  // claimed the bare "cancel" / "never mind" forms that mean "drop the draft",
  // so what reaches here names a record -- "cancel this specific booking",
  // "kanselahin mo yung reservation ko".
  if (hasCancel) return AssistantIntent.cancel;

  // Money, permits and status are all questions about the same records, so they
  // are separated before the generic "show my reservations" branch -- otherwise
  // "how much do I still owe" would answer with a list instead of an amount.
  if (_paymentDeadlineRe.hasMatch(normalized)) {
    return AssistantIntent.paymentDeadline;
  }
  if (_paymentBalanceRe.hasMatch(normalized)) {
    return AssistantIntent.paymentBalance;
  }
  if (_permitRe.hasMatch(normalized)) {
    // "Why is my permit not ready" is about one record; "what do I need for a
    // permit" is about the policy. Ownership language is what separates them.
    return mentionsMine && !_permitRequirementsRe.hasMatch(normalized)
        ? AssistantIntent.permitStatus
        : AssistantIntent.permitRequirements;
  }
  if (mentionsMine && _statusRe.hasMatch(normalized)) {
    return AssistantIntent.reservationStatus;
  }
  if (_announcementRe.hasMatch(normalized)) {
    return AssistantIntent.announcements;
  }
  if (_equipmentRe.hasMatch(normalized) && !hasBookCue) {
    return AssistantIntent.equipment;
  }
  if (_recommendRe.hasMatch(normalized)) {
    return AssistantIntent.recommendFacility;
  }
  if (_policyRe.hasMatch(normalized) && !mentionsMine) {
    return AssistantIntent.policyFaq;
  }

  if (aboutMyRecords && !hasBookCue) return AssistantIntent.myReservations;
  if (hasHelp &&
      !hasBookCue &&
      capacity == null &&
      date == null &&
      time == null) {
    return AssistantIntent.help;
  }
  if (hasPluralVenueWord && (facilityQuery == null || facilityQuery.isEmpty)) {
    return AssistantIntent.findFacilities;
  }
  if (hasAvailableCue &&
      ((facilityQuery != null && facilityQuery.isNotEmpty) ||
          category != null) &&
      (date != null || time != null)) {
    return AssistantIntent.checkAvailability;
  }
  if (hasAvailableCue &&
      !hasBookCue &&
      (facilityQuery == null || facilityQuery.isEmpty) &&
      category == null &&
      capacity == null) {
    return AssistantIntent.findFacilities;
  }
  if (hasBookCue || capacity != null || date != null || time != null) {
    return AssistantIntent.book;
  }
  if (hasListCue) return AssistantIntent.findFacilities;
  return AssistantIntent.unknown;
}
