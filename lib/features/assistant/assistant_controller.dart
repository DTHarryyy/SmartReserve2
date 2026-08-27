library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/reservation.dart';
import '../../util/campus_calendar.dart';
import 'assistant_availability.dart';
import 'assistant_nlu.dart';

enum AssistantStage {
  idle,
  needFacility,
  needDate,
  needTime,
  needHeads,
  needPurpose,
  confirming,
  submitting,
}

enum AssistantSpeaker { user, assistant }

enum AssistantMessageKind { text, chips, facilities, confirm, reservations }

class AssistantChipOption {
  const AssistantChipOption(this.label, this.onSelect);
  final String label;
  final void Function(AppState state) onSelect;
}

class AssistantMessage {
  const AssistantMessage._({
    required this.speaker,
    required this.kind,
    required this.text,
    this.tone,
    this.facilities = const [],
    this.chips = const [],
    this.reservations = const [],
  });

  final AssistantSpeaker speaker;
  final AssistantMessageKind kind;
  final String text;
  final AdvisoryTone? tone;
  final List<Facility> facilities;
  final List<AssistantChipOption> chips;
  final List<ReservationRequest> reservations;

  factory AssistantMessage.user(String text) => AssistantMessage._(
    speaker: AssistantSpeaker.user,
    kind: AssistantMessageKind.text,
    text: text,
  );

  factory AssistantMessage.assistant(String text, {AdvisoryTone? tone}) =>
      AssistantMessage._(
        speaker: AssistantSpeaker.assistant,
        kind: AssistantMessageKind.text,
        text: text,
        tone: tone,
      );

  factory AssistantMessage.chips(
    String text,
    List<AssistantChipOption> chips,
  ) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: AssistantMessageKind.chips,
    text: text,
    chips: chips,
  );

  factory AssistantMessage.facilityList(
    String text,
    List<Facility> facilities,
  ) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: AssistantMessageKind.facilities,
    text: text,
    facilities: facilities,
  );

  factory AssistantMessage.confirmCard(String text) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: AssistantMessageKind.confirm,
    text: text,
  );

  factory AssistantMessage.reservationList(
    String text,
    List<ReservationRequest> reservations,
  ) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: AssistantMessageKind.reservations,
    text: text,
    reservations: reservations,
  );
}

class BookingDraft {
  Facility? facility;
  DateTime? day;
  double? startHour;
  double? endHour;
  int? heads;
  String? purpose;
  List<Facility> candidates = const [];
  final Set<String> amenities = <String>{};

  bool get hasTime => startHour != null && endHour != null;

  AssistantStage get firstMissing {
    if (facility == null) return AssistantStage.needFacility;
    if (day == null) return AssistantStage.needDate;
    if (!hasTime) return AssistantStage.needTime;
    if (heads == null) return AssistantStage.needHeads;
    if (purpose == null || purpose!.trim().length < 3) {
      return AssistantStage.needPurpose;
    }
    return AssistantStage.confirming;
  }
}

class FacilityMatch {
  const FacilityMatch(this.facility, this.score);
  final Facility facility;
  final double score;
}

List<FacilityMatch> resolveFacilityByName(String query, List<Facility> pool) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final qTokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final matches = <FacilityMatch>[];
  for (final facility in pool) {
    final name = facility.name.toLowerCase();
    double score;
    if (name == q) {
      score = 1.0;
    } else if (name.contains(q) ||
        q.contains(name) ||
        facility.room.toLowerCase().contains(q) ||
        facility.building.toLowerCase().contains(q)) {
      score = 0.9;
    } else {
      final nameTokens = name.split(RegExp(r'\s+'));
      var matchedCount = 0;
      for (final token in qTokens) {
        if (nameTokens.any((nt) => fuzzyWordMatches(token, nt))) {
          matchedCount++;
        }
      }
      score = qTokens.isEmpty ? 0 : matchedCount / qTokens.length;
    }
    if (score >= 0.45) matches.add(FacilityMatch(facility, score));
  }
  matches.sort((a, b) => b.score.compareTo(a.score));
  return matches;
}

List<Facility> _tiedTop(List<FacilityMatch> matches) {
  if (matches.isEmpty) return const [];
  final top = matches.first.score;
  return [
    for (final m in matches)
      if (top - m.score < 0.08) m.facility,
  ];
}

const _outOfScopeCues = {
  'grade',
  'grades',
  'enroll',
  'enrollment',
  'tuition',
  'professor',
  'dean',
  'password',
};

final _inScopeCueRe = RegExp(
  r'\b(book|reserve|facility|facilities|room|rooms|venue|venues|available|'
  r'availability|reservation|reservations|cancel)\b',
);

class AssistantController extends ChangeNotifier {
  AssistantController() {
    messages.add(AssistantMessage.assistant(_greeting));
    messages.add(
      AssistantMessage.chips(
        'Try one of these, or just type:',
        _defaultSuggestions(),
      ),
    );
  }

  static const _greeting =
      'Hi! Ask me to find a room, check if a time is free, or book one '
      'right here — for example "book a room for 50 people next Thursday '
      '2 to 4pm".';

  final List<AssistantMessage> messages = [];
  AssistantStage stage = AssistantStage.idle;
  BookingDraft draft = BookingDraft();
  bool busy = false;
  bool _submitting = false;
  bool get submitting => _submitting;

  List<AssistantChipOption> _defaultSuggestions() => [
    AssistantChipOption(
      'What facilities are available?',
      (state) => unawaited(send('What facilities are available?', state)),
    ),
    AssistantChipOption(
      'Book a room for 50 people',
      (state) => unawaited(send('Book a room for 50 people', state)),
    ),
    AssistantChipOption(
      'Is the auditorium free Thursday 2–4pm?',
      (state) =>
          unawaited(send('Is the auditorium free Thursday 2–4pm?', state)),
    ),
    AssistantChipOption(
      'Show my reservations',
      (state) => unawaited(send('Show my reservations', state)),
    ),
  ];

  void _say(String text, {AdvisoryTone? tone}) {
    messages.add(AssistantMessage.assistant(text, tone: tone));
  }

  void _resetDraft() {
    draft = BookingDraft();
    stage = AssistantStage.idle;
  }

  void toggleDraftAmenity(String label) {
    if (!draft.amenities.remove(label)) draft.amenities.add(label);
    notifyListeners();
  }

  void removeDraftAmenity(String label) {
    draft.amenities.remove(label);
    notifyListeners();
  }

  void _runAction(Future<void> Function() action) {
    busy = true;
    notifyListeners();
    unawaited(
      action().whenComplete(() {
        busy = false;
        notifyListeners();
      }),
    );
  }

  Future<void> send(String text, AppState state) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || busy) return;
    messages.add(AssistantMessage.user(trimmed));
    busy = true;
    notifyListeners();
    try {
      final parsed = parseMessage(trimmed, nowWall: campusNow());
      await _handle(parsed, state);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _handle(ParsedMessage p, AppState state) async {
    if (p.abort) {
      _resetDraft();
      _say('Okay, dropped that. What next?');
      messages.add(
        AssistantMessage.chips(
          'Try one of these, or just type:',
          _defaultSuggestions(),
        ),
      );
      return;
    }

    if (_isOutOfScope(p.normalized)) {
      _say("That's outside what I do — I only handle facility reservations.");
      return;
    }

    if (p.recurringCue) {
      _say(
        'I can only do one date at a time here. Once this one is sorted, '
        'use the Book button on the facility card for weekly repeats.',
      );
    }

    if (stage == AssistantStage.confirming) {
      if (p.affirmation == true) {
        await confirm(state);
        return;
      }
      if (p.affirmation == false) {
        _resetDraft();
        _say('Okay, cancelled. What next?');
        return;
      }
      if (p.hasSlots) {
        _mergeSlots(p, state);
        await _advanceDraft(state);
        return;
      }
    } else if (stage != AssistantStage.idle) {
      if (_fillsCurrentStage(p)) {
        _mergeSlots(p, state);
      } else {
        _applyStageScopedFallback(p, state);
      }
      await _advanceDraft(state);
      return;
    }

    switch (p.intent) {
      case AssistantIntent.findFacilities:
        _handleFindFacilities(p, state);
        break;
      case AssistantIntent.checkAvailability:
        await _handleCheckAvailability(p, state);
        break;
      case AssistantIntent.book:
        _mergeSlots(p, state);
        await _advanceDraft(state);
        break;
      case AssistantIntent.myReservations:
        _handleMyReservations(state);
        break;
      case AssistantIntent.cancel:
        _handleCancelRequest(state);
        break;
      case AssistantIntent.help:
        _say(
          'I can: find facilities, check if a time is free, book a room, '
          'show your reservations, or cancel one. Try one of these:',
        );
        messages.add(AssistantMessage.chips('', _defaultSuggestions()));
        break;
      case AssistantIntent.unknown:
        _say(
          "I didn't catch that. I can find facilities, check if a time "
          'is free, book, or show your reservations.',
        );
        messages.add(AssistantMessage.chips('', _defaultSuggestions()));
        break;
    }
  }

  bool _fillsCurrentStage(ParsedMessage p) {
    switch (stage) {
      case AssistantStage.needFacility:
        return (p.facilityQuery != null && p.facilityQuery!.isNotEmpty) ||
            p.ordinal != null ||
            p.category != null ||
            p.amenities.isNotEmpty ||
            p.capacity != null;
      case AssistantStage.needDate:
        return p.date != null;
      case AssistantStage.needTime:
        return p.time != null;
      case AssistantStage.needHeads:
        return p.capacity != null;
      case AssistantStage.needPurpose:
        return p.purpose != null && p.purpose!.trim().length >= 3;
      case AssistantStage.idle:
      case AssistantStage.confirming:
      case AssistantStage.submitting:
        return p.hasSlots;
    }
  }

  bool _isOutOfScope(String normalized) {
    if (_inScopeCueRe.hasMatch(normalized)) return false;
    return _outOfScopeCues.any((cue) => normalized.contains(cue));
  }

  void _mergeSlots(ParsedMessage p, AppState state) {
    if (p.capacity != null) {
      final n = p.capacity!.max ?? p.capacity!.min;
      if (draft.facility != null && n > draft.facility!.capacity) {
        _say(
          '${draft.facility!.name} seats ${draft.facility!.capacity} and '
          'you said $n.',
        );
        _suggestBiggerFacilities(n, state);
      } else {
        draft.heads = n;
      }
    }

    if (p.date != null) {
      if (p.date!.invalid) {
        _say('That date doesn\'t look right — try something like "Aug 20".');
      } else {
        draft.day = p.date!.day;
      }
    }

    if (p.time != null) {
      final start = p.time!.startHour;
      if (start != null) {
        final end = p.time!.endHour ?? start + 2;
        if (p.time!.endHour == null) {
          _say('Assuming 2 hours — say "3 hours" to change it.');
        }
        draft.startHour = start;
        draft.endHour = end;
      }
    }

    if (p.purpose != null) {
      draft.purpose = p.purpose;
    }

    if (p.amenities.isNotEmpty) {
      final newOnes = p.amenities.difference(draft.amenities);
      draft.amenities.addAll(p.amenities);
      if (newOnes.isNotEmpty && draft.facility != null) {
        _say("Noted — I'll ask for ${newOnes.join(' and ')} with it.");
      }
    }

    if (p.unknownAmenityWords.isNotEmpty) {
      _say(
        "I don't track '${p.unknownAmenityWords.first}' as an amenity. I "
        'know about ${knownAmenityLabels.join(', ')}.',
      );
    }

    final wantsFacilitySearch =
        p.facilityQuery != null ||
        p.capacity != null ||
        p.amenities.isNotEmpty ||
        p.category != null;
    if (draft.facility == null && wantsFacilitySearch) {
      _resolveFacility(p, state);
    } else if (p.ordinal != null && draft.candidates.isNotEmpty) {
      final index = p.ordinal! - 1;
      if (index >= 0 && index < draft.candidates.length) {
        draft.facility = draft.candidates[index];
        draft.candidates = const [];
      }
    }
  }

  void _resolveFacility(ParsedMessage p, AppState state) {
    final pool = state.bookableFacilities;
    if (pool.isEmpty) {
      _say("Give me a second — I'm still loading the campus list.");
      return;
    }

    if (p.facilityQuery != null && p.facilityQuery!.isNotEmpty) {
      final matches = resolveFacilityByName(p.facilityQuery!, pool);
      if (matches.isNotEmpty) {
        final tied = _tiedTop(matches);
        if (tied.length == 1) {
          draft.facility = tied.first;
          draft.candidates = const [];
        } else {
          draft.candidates = tied;
          _say('A few rooms match "${p.facilityQuery}" — which one?');
          messages.add(AssistantMessage.facilityList('', tied));
        }
        return;
      }
    }

    final amenities = p.amenities;
    final minCapacity = p.capacity?.min ?? draft.heads ?? 0;
    final category = p.category ?? 'All categories';
    var results = state.searchFacilities(
      minCapacity: minCapacity,
      amenities: amenities,
      category: category,
    );

    if (results.isEmpty && amenities.isNotEmpty) {
      results = state.searchFacilities(
        minCapacity: minCapacity,
        category: category,
      );
      if (results.isNotEmpty) {
        _say(
          'No bookable room has ${amenities.join(' and ')} and seats '
          '$minCapacity+ — these seat $minCapacity+ without that:',
        );
      }
    }
    if (results.isEmpty && category != 'All categories') {
      results = state.searchFacilities(minCapacity: minCapacity);
      if (results.isNotEmpty) {
        _say("Nothing in that category fits — here's what does:");
      }
    }
    if (results.isEmpty && minCapacity > 0) {
      final biggest = [...state.bookableFacilities]
        ..sort((a, b) => b.capacity.compareTo(a.capacity));
      if (biggest.isNotEmpty && biggest.first.capacity < minCapacity) {
        final top = biggest.take(3).toList();
        _say(
          'The biggest bookable space is ${top.first.name} '
          '(${top.first.capacity} seats), short of $minCapacity. Want to '
          'see it anyway?',
        );
        messages.add(AssistantMessage.facilityList('', top));
        return;
      }
      results = biggest.take(3).toList();
    }

    if (results.length == 1) {
      draft.facility = results.first;
      messages.add(AssistantMessage.facilityList('Best match:', results));
    } else if (results.length > 1) {
      draft.candidates = results;
      _say('A few rooms fit — which one?');
      messages.add(AssistantMessage.facilityList('', results));
    } else {
      _say(
        "I couldn't find a bookable room matching that. Which facility did you mean?",
      );
    }
  }

  void _suggestBiggerFacilities(int minCapacity, AppState state) {
    final bigger =
        state.bookableFacilities
            .where((f) => f.capacity >= minCapacity)
            .toList()
          ..sort((a, b) => a.capacity.compareTo(b.capacity));
    if (bigger.isNotEmpty) {
      messages.add(
        AssistantMessage.facilityList(
          'Bigger options:',
          bigger.take(3).toList(),
        ),
      );
    }
  }

  void _applyStageScopedFallback(ParsedMessage p, AppState state) {
    switch (stage) {
      case AssistantStage.needFacility:
        if (draft.candidates.isNotEmpty && p.ordinal != null) {
          final index = p.ordinal! - 1;
          if (index >= 0 && index < draft.candidates.length) {
            draft.facility = draft.candidates[index];
            draft.candidates = const [];
            return;
          }
        }
        final pool = state.bookableFacilities;
        final matches = resolveFacilityByName(p.raw, pool);
        if (matches.isNotEmpty) {
          final tied = _tiedTop(matches);
          if (tied.length == 1) {
            draft.facility = tied.first;
            draft.candidates = const [];
          } else {
            draft.candidates = tied;
            _say('A few rooms match that — which one?');
            messages.add(AssistantMessage.facilityList('', tied));
          }
        } else {
          _say(
            'I still don\'t recognise that facility. Try a shorter name, like "auditorium".',
          );
        }
        break;
      case AssistantStage.needPurpose:
        final text = p.raw.trim();
        if (text.length >= 3) {
          draft.purpose = text.length > 280 ? text.substring(0, 280) : text;
        } else {
          _say("A few words is enough — what's the event or activity?");
        }
        break;
      case AssistantStage.needHeads:
        final match = RegExp(r'\d+').firstMatch(p.raw);
        final n = match != null ? int.tryParse(match.group(0)!) : null;
        if (n != null && n >= 1 && n <= 5000) {
          draft.heads = n;
        } else {
          _say('Just a number is fine — about how many people?');
        }
        break;
      case AssistantStage.needDate:
      case AssistantStage.needTime:
      case AssistantStage.confirming:
      case AssistantStage.idle:
      case AssistantStage.submitting:
        _say("I didn't catch that — could you say it differently?");
        break;
    }
  }

  Future<void> _advanceDraft(AppState state) async {
    if (draft.facility == null && draft.candidates.isNotEmpty) {
      stage = AssistantStage.needFacility;
      return;
    }

    stage = draft.firstMissing;
    switch (stage) {
      case AssistantStage.needFacility:
        _say('Which facility did you have in mind?');
        break;
      case AssistantStage.needDate:
        _say('What date works?');
        _offerOpenDayChips(state);
        break;
      case AssistantStage.needTime:
        await _offerTimeChips(state);
        break;
      case AssistantStage.needHeads:
        _say('About how many people?');
        break;
      case AssistantStage.needPurpose:
        _say(
          "What's it for? One sentence is enough — the assigned administrator reads this.",
        );
        break;
      case AssistantStage.confirming:
        await _renderConfirmCard(state);
        break;
      case AssistantStage.idle:
      case AssistantStage.submitting:
        break;
    }
  }

  void _offerOpenDayChips(AppState state) {
    final facility = draft.facility;
    if (facility == null) return;
    final today = campusNow();
    final options = <AssistantChipOption>[];
    var day = DateTime(today.year, today.month, today.day);
    var count = 0;
    var guard = 0;
    while (count < 5 && guard < 30) {
      if (facility.opensOn(day)) {
        final chosen = day;
        options.add(
          AssistantChipOption(
            formatCampusDate(chosen),
            (s) => _runAction(() => _selectDay(chosen, s)),
          ),
        );
        count++;
      }
      day = day.add(const Duration(days: 1));
      guard++;
    }
    if (options.isNotEmpty) {
      messages.add(AssistantMessage.chips('', options));
    }
  }

  Future<void> _selectDay(DateTime day, AppState state) async {
    draft.day = day;
    await _advanceDraft(state);
  }

  Future<void> _offerTimeChips(AppState state) async {
    final facility = draft.facility;
    final day = draft.day;
    if (facility == null || day == null) return;
    final duration = draft.hasTime ? draft.endHour! - draft.startHour! : 2.0;
    final busy = await state.busyWindowsFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
    );
    final key = '${facility.id}|${dayKey(day)}';
    final slots = freeSlotsForDay(
      facility: facility,
      day: day,
      busy: busy[key] ?? const [],
      durationHours: duration,
      nowWall: campusNow(),
    );
    if (slots.isEmpty) {
      _say(
        '${facility.name} looks fully booked that day. Want to try another date?',
      );
      draft.day = null;
      stage = AssistantStage.needDate;
      _offerOpenDayChips(state);
      return;
    }
    _say("What time? Here's what's open:");
    messages.add(
      AssistantMessage.chips('', [
        for (final slot in slots)
          AssistantChipOption(
            slot.label,
            (s) =>
                _runAction(() => _selectSlot(slot.startHour, slot.endHour, s)),
          ),
      ]),
    );
  }

  Future<void> _selectSlot(double start, double end, AppState state) async {
    draft.startHour = start;
    draft.endHour = end;
    await _advanceDraft(state);
  }

  void _emitIssues(
    SlotVerdict verdict,
    AppState state,
    Facility facility,
    DateTime day,
  ) {
    for (final issue in verdict.issues) {
      switch (issue) {
        case SlotIssue.closedDay:
          _say(
            '${facility.name} runs ${facility.days}, so ${formatCampusDate(day)} is out.',
          );
          draft.day = null;
          break;
        case SlotIssue.outsideHours:
          _say(
            '${facility.name} runs ${facility.hours}. That falls outside those hours.',
          );
          draft.startHour = null;
          draft.endHour = null;
          break;
        case SlotIssue.tooLong:
          _say(
            "That's longer than this room allows "
            '(max ${facility.maxDuration}).',
          );
          draft.startHour = null;
          draft.endHour = null;
          break;
        case SlotIssue.inPast:
          _say(
            "I can't book a time that's already passed. What's a future date or time?",
          );
          draft.day = null;
          draft.startHour = null;
          draft.endHour = null;
          break;
        case SlotIssue.beyondAdvance:
          final today = campusNow();
          final limit = DateTime(
            today.year,
            today.month,
            today.day,
          ).add(Duration(days: facility.advanceBookingDays));
          _say(
            'Bookings for ${facility.name} open only '
            '${facility.advanceBookingDays} days ahead — the furthest I '
            'can go is ${formatCampusDate(limit)}.',
          );
          draft.day = null;
          break;
        case SlotIssue.overCapacity:
          _say(
            '${facility.name} seats ${facility.capacity}'
            '${draft.heads != null ? " and you said ${draft.heads}" : ""}.',
          );
          _suggestBiggerFacilities(
            (draft.heads ?? facility.capacity) + 1,
            state,
          );
          draft.heads = null;
          break;
        case SlotIssue.clash:
          _say('That time is taken.');
          break;
        case SlotIssue.facilityUnavailable:
          _say('${facility.name} is closed for maintenance right now.');
          draft.facility = null;
          break;
        case SlotIssue.zeroDuration:
          _say(
            "That end time isn't after the start — what time range did you mean?",
          );
          draft.startHour = null;
          draft.endHour = null;
          break;
      }
    }
    if (verdict.issues.contains(SlotIssue.clash)) {
      unawaited(_offerTimeChips(state));
    }
  }

  Future<void> _renderConfirmCard(AppState state) async {
    final facility = draft.facility!;
    final day = draft.day!;
    final busy = await state.busyWindowsFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
    );
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: draft.startHour!,
      endHour: draft.endHour!,
      heads: draft.heads!,
      busy: busy['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!verdict.ok) {
      _emitIssues(verdict, state, facility, day);
      stage = draft.firstMissing;
      return;
    }
    messages.add(AssistantMessage.confirmCard('Ready to send:'));
  }

  Future<void> confirm(AppState state) async {
    if (_submitting || state.reservationActionsPending.contains('submit')) {
      return;
    }
    final facility = draft.facility;
    final day = draft.day;
    final startHour = draft.startHour;
    final endHour = draft.endHour;
    final heads = draft.heads;
    final purpose = draft.purpose;
    if (facility == null ||
        day == null ||
        startHour == null ||
        endHour == null ||
        heads == null ||
        purpose == null) {
      await _advanceDraft(state);
      notifyListeners();
      return;
    }

    if (state.userAccount.status == AccountStatus.suspended) {
      _say(
        state.userAccount.suspendReason ??
            'This account is suspended and cannot submit new requests.',
        tone: AdvisoryTone.block,
      );
      notifyListeners();
      return;
    }

    final busy = await state.busyWindowsFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
    );
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: startHour,
      endHour: endHour,
      heads: heads,
      busy: busy['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!verdict.ok) {
      _emitIssues(verdict, state, facility, day);
      stage = draft.firstMissing;
      notifyListeners();
      return;
    }

    final startWall = DateTime(
      day.year,
      day.month,
      day.day,
      startHour.floor(),
      ((startHour % 1) * 60).round(),
    );
    final endWall = DateTime(
      day.year,
      day.month,
      day.day,
      endHour.floor(),
      ((endHour % 1) * 60).round(),
    );

    _submitting = true;
    stage = AssistantStage.submitting;
    notifyListeners();

    final requestedAmenities = draft.amenities.toList();
    final quote = await state.quoteReservation(
      facility: facility,
      startsAt: [campusInstant(startWall)],
      endsAt: [campusInstant(endWall)],
      headcount: heads,
      amenities: requestedAmenities,
    );
    if (quote == null || quote.terms.isNotEmpty) {
      _submitting = false;
      stage = AssistantStage.confirming;
      _say(
        quote == null
            ? state.lastReservationError ?? 'The server quote is unavailable.'
            : 'Open ${facility.name} from Browse to review the exact price and accept the current terms before sending.',
        tone: quote == null ? AdvisoryTone.block : AdvisoryTone.info,
      );
      notifyListeners();
      return;
    }
    final ok = await state.submitReservationRequest(
      facility: facility,
      startsAt: [campusInstant(startWall)],
      endsAt: [campusInstant(endWall)],
      heads: heads,
      purpose: purpose.trim(),
      amenities: requestedAmenities,
      quote: quote,
      acceptedTerms: true,
    );

    _submitting = false;
    state.invalidateBusyCache(facility.id, day);

    if (ok) {
      _say(
        'Sent. ${facility.name}, ${formatCampusDate(day)} '
        '${formatClockHour(startHour)}–${formatClockHour(endHour)}. '
        'The assigned ${quote.adminLane} administrator will decide — check My reservations for updates.'
        '${requestedAmenities.isEmpty ? '' : ' Requested: ${requestedAmenities.join(', ')}.'}',
      );
      _resetDraft();
    } else {
      _say(
        state.lastReservationError ??
            "That didn't go through — see the message above.",
        tone: AdvisoryTone.block,
      );
      draft.facility = facility;
      draft.day = day;
      draft.startHour = null;
      draft.endHour = null;
      draft.heads = heads;
      draft.purpose = purpose;
      await _offerTimeChips(state);
      stage = AssistantStage.needTime;
    }
    notifyListeners();
  }

  void _handleFindFacilities(ParsedMessage p, AppState state) {
    final results = state.searchFacilities(
      minCapacity: p.capacity?.min ?? 0,
      amenities: p.amenities,
      category: p.category ?? 'All categories',
    );
    if (results.isEmpty) {
      _say('Nothing bookable matches that right now.');
      return;
    }
    _say(
      results.length == 1
          ? 'One match:'
          : '${results.length} facilities match:',
    );
    messages.add(AssistantMessage.facilityList('', results.take(8).toList()));
  }

  Future<void> _handleCheckAvailability(ParsedMessage p, AppState state) async {
    if (p.date?.invalid == true) {
      _say('That date doesn\'t look right — try something like "Aug 20".');
      return;
    }

    final pool = state.bookableFacilities;
    List<Facility> candidates;
    if (p.facilityQuery != null && p.facilityQuery!.isNotEmpty) {
      final matches = resolveFacilityByName(p.facilityQuery!, pool);
      if (matches.isEmpty) {
        _say('I couldn\'t find a bookable room called "${p.facilityQuery}".');
        return;
      }
      candidates = _tiedTop(matches);
    } else if (p.category != null) {
      candidates = pool.where((f) => f.category == p.category).toList();
    } else {
      candidates = pool;
    }

    if (candidates.isEmpty) {
      _say("I couldn't find a bookable room matching that.");
      return;
    }
    if (candidates.length > 1) {
      _say('Which one?');
      messages.add(
        AssistantMessage.facilityList('', candidates.take(8).toList()),
      );
      return;
    }

    final facility = candidates.first;
    final day = p.date?.day ?? campusNow();
    final duration = p.time?.durationHours ?? 2.0;

    final busy = await state.busyWindowsFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
    );
    final key = '${facility.id}|${dayKey(day)}';
    final degradedNote = state.busyWindowsDegraded
        ? " (based on opening hours only — I couldn't reach the live schedule)"
        : '';

    if (p.time?.startHour != null && p.time?.endHour != null) {
      final start = p.time!.startHour!;
      final end = p.time!.endHour!;
      final verdict = checkSlot(
        facility: facility,
        day: day,
        startHour: start,
        endHour: end,
        heads: 1,
        busy: busy[key] ?? const [],
        nowWall: campusNow(),
      );
      if (verdict.ok) {
        _say(
          '${facility.name} is free ${formatClockHour(start)}–'
          '${formatClockHour(end)} on ${formatCampusDate(day)}.$degradedNote',
        );
        messages.add(
          AssistantMessage.chips('Want to book it?', [
            AssistantChipOption(
              'Yes, book it',
              (s) => _runAction(
                () => _startBookingFromCheck(facility, day, start, end, s),
              ),
            ),
          ]),
        );
      } else if (verdict.issues.length == 1 &&
          verdict.issues.contains(SlotIssue.clash)) {
        _say(
          '${facility.name} is taken ${formatClockHour(start)}–'
          '${formatClockHour(end)} on ${formatCampusDate(day)}.',
        );
        final slots = freeSlotsForDay(
          facility: facility,
          day: day,
          busy: busy[key] ?? const [],
          durationHours: duration,
          nowWall: campusNow(),
        );
        if (slots.isNotEmpty) {
          _say('Still open that day:');
          messages.add(
            AssistantMessage.chips('', [
              for (final slot in slots)
                AssistantChipOption(
                  slot.label,
                  (s) => _runAction(
                    () => _startBookingFromCheck(
                      facility,
                      day,
                      slot.startHour,
                      slot.endHour,
                      s,
                    ),
                  ),
                ),
            ]),
          );
        }
      } else {
        _emitIssues(verdict, state, facility, day);
      }
      return;
    }

    final slots = freeSlotsForDay(
      facility: facility,
      day: day,
      busy: busy[key] ?? const [],
      durationHours: duration,
      nowWall: campusNow(),
    );
    if (slots.isEmpty) {
      _say(
        '${facility.name} looks fully booked on ${formatCampusDate(day)}.$degradedNote',
      );
      return;
    }
    _say('${facility.name} is open ${formatCampusDate(day)}:$degradedNote');
    messages.add(
      AssistantMessage.chips('', [
        for (final slot in slots)
          AssistantChipOption(
            slot.label,
            (s) => _runAction(
              () => _startBookingFromCheck(
                facility,
                day,
                slot.startHour,
                slot.endHour,
                s,
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> chooseFacility(Facility facility, AppState state) async {
    draft.facility = facility;
    draft.candidates = const [];
    await _advanceDraft(state);
    notifyListeners();
  }

  void noteCancelled(ReservationRequest request) {
    _say('Cancelled ${request.facility} on ${request.whenLabel}.');
    notifyListeners();
  }

  void discardDraft() {
    _resetDraft();
    _say('Okay, cancelled. What next?');
    notifyListeners();
  }

  Future<void> _startBookingFromCheck(
    Facility facility,
    DateTime day,
    double start,
    double end,
    AppState state,
  ) async {
    draft.facility = facility;
    draft.day = day;
    draft.startHour = start;
    draft.endHour = end;
    await _advanceDraft(state);
  }

  void _handleMyReservations(AppState state) {
    final mine = state.myRequests;
    if (mine.isEmpty) {
      _say('Nothing booked yet. Try the Browse tab to find a room.');
      return;
    }
    _say(
      mine.length == 1
          ? "Here's your reservation:"
          : 'Here are your reservations:',
    );
    messages.add(AssistantMessage.reservationList('', mine));
  }

  void _handleCancelRequest(AppState state) {
    final mine = state.myRequests;
    final cancellable = [
      for (final r in mine)
        if (state.canCancelReservation(r)) r,
    ];
    if (cancellable.isEmpty) {
      _say(
        mine.isEmpty
            ? 'Nothing booked yet, so nothing to cancel.'
            : 'Nothing of yours can be cancelled right now — already decided or in the past.',
      );
      return;
    }
    _say(
      cancellable.length == 1
          ? 'Here it is — tap Cancel to confirm:'
          : 'Which one? Tap Cancel on the one you want to drop:',
    );
    messages.add(AssistantMessage.reservationList('', cancellable));
  }
}
