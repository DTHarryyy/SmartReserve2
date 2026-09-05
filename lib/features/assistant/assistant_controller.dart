library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/account.dart';
import '../../model/amenity_request.dart';
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

enum AssistantMessageKind {
  text,
  chips,
  facilities,
  confirm,
  reservations,
  activity,
}

enum _StageInputResult { accepted, rejected, needsSelection }

enum _HeadcountProblem { missing, negative, fractional, ambiguous, invalid }

class _HeadcountParse {
  const _HeadcountParse({this.value, this.problem});

  final int? value;
  final _HeadcountProblem? problem;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class AssistantChipOption {
  const AssistantChipOption(this.label, this.onSelect);
  final String label;
  final void Function(AppState state) onSelect;
}

enum AssistantPickerKind { facility, date, time }

enum AssistantPickerStatus { loading, ready, empty, error }

sealed class AssistantPickerPrompt {
  const AssistantPickerPrompt({
    required this.revision,
    required this.status,
    required this.title,
    required this.subtitle,
    this.error,
  });

  final int revision;
  final AssistantPickerStatus status;
  final String title;
  final String subtitle;
  final String? error;

  AssistantPickerKind get kind;
}

class FacilityPickerPrompt extends AssistantPickerPrompt {
  const FacilityPickerPrompt({
    required super.revision,
    required super.status,
    required super.title,
    required super.subtitle,
    required this.recommended,
    required this.allMatches,
    super.error,
  });

  @override
  AssistantPickerKind get kind => AssistantPickerKind.facility;

  final List<Facility> recommended;
  final List<Facility> allMatches;
}

class DatePickerPrompt extends AssistantPickerPrompt {
  const DatePickerPrompt({
    required super.revision,
    required super.status,
    required super.title,
    required super.subtitle,
    required this.recommended,
    required this.availableDays,
    required this.firstDate,
    required this.lastDate,
    required this.requiredDurationHours,
    super.error,
  });

  @override
  AssistantPickerKind get kind => AssistantPickerKind.date;

  final List<AvailableBookingDay> recommended;
  final Set<DateTime> availableDays;
  final DateTime firstDate;
  final DateTime lastDate;
  final double requiredDurationHours;
}

class TimePickerPrompt extends AssistantPickerPrompt {
  const TimePickerPrompt({
    required super.revision,
    required super.status,
    required super.title,
    required super.subtitle,
    required this.recommended,
    required this.allSlots,
    required this.busyWindows,
    required this.openHour,
    required this.closeHour,
    required this.maxDurationMinutes,
    required this.bufferMinutes,
    required this.day,
    required this.requiredDurationHours,
    super.error,
  });

  @override
  AssistantPickerKind get kind => AssistantPickerKind.time;

  final List<FreeSlot> recommended;
  final List<FreeSlot> allSlots;
  final List<BusyWindow> busyWindows;
  final int openHour;
  final int closeHour;
  final int maxDurationMinutes;
  final int bufferMinutes;
  final DateTime day;
  final double requiredDurationHours;
}

String assistantFacilityOptionId(Facility facility) =>
    'facility:${facility.id}';

String assistantDateOptionId(DateTime day) => 'date:${dayKey(day)}';

String assistantTimeOptionId(double startHour, double endHour) {
  String clockId(double hour) => formatClockHour(hour).replaceAll(':', '');
  return 'time:${clockId(startHour)}-${clockId(endHour)}';
}

class AssistantMessage {
  AssistantMessage._({
    required this.speaker,
    required this.kind,
    required this.text,
    this.tone,
    this.facilities = const [],
    this.chips = const [],
    this.reservations = const [],
    this.reservationId,
    this.action,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final AssistantSpeaker speaker;
  final AssistantMessageKind kind;
  final String text;
  final AdvisoryTone? tone;
  final List<Facility> facilities;
  final List<AssistantChipOption> chips;
  final List<ReservationRequest> reservations;
  final String? reservationId;
  final String? action;
  final DateTime createdAt;

  factory AssistantMessage.user(String text) => AssistantMessage._(
    speaker: AssistantSpeaker.user,
    kind: AssistantMessageKind.text,
    text: text,
  );

  factory AssistantMessage.assistant(
    String text, {
    AdvisoryTone? tone,
    String? reservationId,
    String? action,
  }) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: AssistantMessageKind.text,
    text: text,
    tone: tone,
    reservationId: reservationId,
    action: action,
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

  factory AssistantMessage.activity(
    String text, {
    String? reservationId,
    String? action,
  }) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: AssistantMessageKind.activity,
    text: text,
    reservationId: reservationId,
    action: action,
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
    _seedGreeting();
  }

  static const _greeting =
      'Hi! Ask me to find a room, check if a time is free, or book one '
      'right here — for example "book a room for 50 people next Thursday '
      '2 to 4pm".';

  final List<AssistantMessage> messages = [];
  final List<BackendAssistantConversation> conversations = [];
  AssistantStage stage = AssistantStage.idle;
  BookingDraft draft = BookingDraft();
  bool busy = false;
  bool historyLoading = false;
  bool historySaveFailed = false;
  String? conversationId;
  AssistantPickerPrompt? activePicker;
  String? _accountId;
  AppState? _state;
  Future<void> _writeQueue = Future.value();
  int _persistedMessageCount = 0;
  int _pickerRevision = 0;
  String? _lastPromptKey;
  bool _submitting = false;
  bool get submitting => _submitting;
  bool get hasHistory => conversationId != null;

  Future<void> initialize(AppState state, {bool freshVisit = false}) async {
    final accountId = state.userAccount.id;
    if (freshVisit && _accountId == accountId && _isResumableStage(stage)) {
      _state = state;
      if (stage != AssistantStage.confirming && activePicker == null) {
        await _advanceDraft(state);
      }
      notifyListeners();
      return;
    }
    if (!freshVisit &&
        _accountId == accountId &&
        (messages.isNotEmpty || historyLoading)) {
      return;
    }
    _state = state;
    _accountId = accountId;
    historyLoading = true;
    historySaveFailed = false;
    messages.clear();
    conversations.clear();
    conversationId = null;
    _persistedMessageCount = 0;
    draft = BookingDraft();
    stage = AssistantStage.idle;
    clearActivePicker();
    notifyListeners();
    try {
      if (state.assistantHistoryAvailable) {
        conversations.addAll(await state.assistantConversations());
        final resumable = conversations
            .where(
              (conversation) => _isResumableDraft(conversation.activeDraft),
            )
            .firstOrNull;
        if (resumable != null) {
          await _loadConversation(resumable, state);
        } else {
          _startLocalConversation();
        }
      } else {
        _startLocalConversation();
      }
    } catch (_) {
      _startLocalConversation();
      historySaveFailed = true;
    } finally {
      historyLoading = false;
      notifyListeners();
    }
  }

  bool _isResumableStage(AssistantStage value) => const {
    AssistantStage.needFacility,
    AssistantStage.needDate,
    AssistantStage.needTime,
    AssistantStage.needHeads,
    AssistantStage.needPurpose,
    AssistantStage.confirming,
  }.contains(value);

  bool _isResumableDraft(Map<String, dynamic> payload) {
    final stageName = payload['stage'] as String?;
    if (stageName == null) return false;
    final restoredStage = AssistantStage.values.where(
      (value) => value.name == stageName,
    );
    if (restoredStage.isEmpty) return false;
    return _isResumableStage(restoredStage.first);
  }

  void _seedGreeting() {
    if (messages.isNotEmpty) return;
    messages.add(AssistantMessage.assistant(_greeting));
    messages.add(
      AssistantMessage.chips(
        'Try one of these, or just type:',
        _defaultSuggestions(),
      ),
    );
    _queueSync();
  }

  void _startLocalConversation() {
    messages.clear();
    draft = BookingDraft();
    stage = AssistantStage.idle;
    clearActivePicker();
    conversationId = null;
    _persistedMessageCount = 0;
    _seedGreeting();
  }

  Future<void> _ensureConversation(AppState state) async {
    if (conversationId != null || !state.assistantHistoryAvailable) return;
    try {
      final conversation = await state.createAssistantConversation(
        title: _conversationTitle(),
        activeDraft: _draftPayload(),
      );
      conversations.removeWhere((item) => item.id == conversation.id);
      conversations.insert(0, conversation);
      conversationId = conversation.id;
      _persistedMessageCount = 0;
      historySaveFailed = false;
    } catch (_) {
      historySaveFailed = true;
    }
  }

  Future<void> newConversation(AppState state, {bool notify = true}) async {
    _state = state;
    await _queueSync();
    _startLocalConversation();
    if (notify) notifyListeners();
  }

  Future<void> openConversation(
    BackendAssistantConversation conversation,
    AppState state,
  ) async {
    _state = state;
    await _queueSync();
    historyLoading = true;
    notifyListeners();
    try {
      await _loadConversation(conversation, state);
    } finally {
      historyLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshHistory(AppState state) async {
    if (!state.assistantHistoryAvailable) return;
    conversations
      ..clear()
      ..addAll(await state.assistantConversations());
    notifyListeners();
  }

  Future<void> retryHistorySave() async {
    historySaveFailed = false;
    notifyListeners();
    await _queueSync();
  }

  Future<void> _loadConversation(
    BackendAssistantConversation conversation,
    AppState state,
  ) async {
    conversationId = conversation.id;
    messages
      ..clear()
      ..addAll(
        (await state.assistantMessages(
          conversation.id,
        )).map((message) => _fromBackendMessage(message, state)),
      );
    _persistedMessageCount = messages.length;
    _restoreDraft(conversation.activeDraft, state);
    if (messages.isEmpty) _seedGreeting();
    clearActivePicker();
    if (stage != AssistantStage.idle && stage != AssistantStage.confirming) {
      await _advanceDraft(state);
    }
  }

  AssistantMessage _fromBackendMessage(
    BackendAssistantMessage message,
    AppState state,
  ) {
    final kind = AssistantMessageKind.values.firstWhere(
      (value) => value.name == message.messageType,
      orElse: () => AssistantMessageKind.text,
    );
    final speaker = message.sender == 'user'
        ? AssistantSpeaker.user
        : AssistantSpeaker.assistant;
    final ids = (message.payload['facility_ids'] as List? ?? const [])
        .map((value) => '$value')
        .toSet();
    final facilities = [
      for (final facility in state.facilities)
        if (ids.contains(facility.id)) facility,
    ];
    final reservationIds =
        (message.payload['reservation_ids'] as List? ?? const [])
            .map((value) => '$value')
            .toSet();
    final reservations = [
      for (final request in state.myRequests)
        if (reservationIds.contains(request.id)) request,
    ];
    final labels = (message.payload['chip_labels'] as List? ?? const [])
        .map((value) => '$value')
        .toList();
    final toneName = message.payload['tone'] as String?;
    final tone = AdvisoryTone.values
        .where((value) => value.name == toneName)
        .firstOrNull;
    return AssistantMessage._(
      speaker: speaker,
      kind: kind,
      text: message.text,
      tone: tone,
      facilities: facilities,
      reservations: reservations,
      chips: [
        for (final label in labels)
          AssistantChipOption(
            label,
            (current) => unawaited(send(label, current)),
          ),
      ],
      reservationId: message.reservationId,
      action: message.action,
      createdAt: message.createdAt.toLocal(),
    );
  }

  Map<String, dynamic> _messagePayload(AssistantMessage message) => {
    if (message.tone != null) 'tone': message.tone!.name,
    if (message.facilities.isNotEmpty)
      'facility_ids': [for (final item in message.facilities) item.id],
    if (message.reservations.isNotEmpty)
      'reservation_ids': [for (final item in message.reservations) item.id],
    if (message.chips.isNotEmpty)
      'chip_labels': [for (final item in message.chips) item.label],
  };

  Map<String, dynamic> _draftPayload() => {
    'stage': stage.name,
    if (draft.facility != null) 'facility_id': draft.facility!.id,
    if (draft.day != null) 'day': draft.day!.toIso8601String(),
    if (draft.startHour != null) 'start_hour': draft.startHour,
    if (draft.endHour != null) 'end_hour': draft.endHour,
    if (draft.heads != null) 'heads': draft.heads,
    if (draft.purpose != null) 'purpose': draft.purpose,
    if (draft.amenities.isNotEmpty) 'amenities': draft.amenities.toList(),
    if (draft.candidates.isNotEmpty)
      'candidate_ids': [for (final item in draft.candidates) item.id],
  };

  void _restoreDraft(Map<String, dynamic> payload, AppState state) {
    if (payload.isEmpty) return;
    final byId = {
      for (final facility in state.facilities) facility.id: facility,
    };
    final restored = BookingDraft()
      ..facility = byId[payload['facility_id']]
      ..day = DateTime.tryParse('${payload['day'] ?? ''}')
      ..startHour = (payload['start_hour'] as num?)?.toDouble()
      ..endHour = (payload['end_hour'] as num?)?.toDouble()
      ..heads = (payload['heads'] as num?)?.toInt()
      ..purpose = payload['purpose'] as String?
      ..candidates = [
        for (final id in (payload['candidate_ids'] as List? ?? const []))
          if (byId['$id'] != null) byId['$id']!,
      ];
    restored.amenities.addAll(
      (payload['amenities'] as List? ?? const []).map((value) => '$value'),
    );
    draft = restored;
    stage = AssistantStage.values.firstWhere(
      (value) => value.name == payload['stage'],
      orElse: () => restored.firstMissing,
    );
  }

  String _conversationTitle() {
    final first = messages
        .where((item) => item.speaker == AssistantSpeaker.user)
        .firstOrNull;
    if (first == null || first.text.trim().isEmpty) return 'New chat';
    final value = first.text.trim();
    return value.length <= 60 ? value : '${value.substring(0, 57)}…';
  }

  Future<void> _queueSync() {
    final state = _state;
    final id = conversationId;
    if (state == null || id == null || !state.assistantHistoryAvailable) {
      return Future.value();
    }
    _writeQueue = _writeQueue.then((_) async {
      final firstPending = _persistedMessageCount;
      try {
        if (firstPending < messages.length) {
          await state.appendAssistantMessages(id, [
            for (final message in messages.skip(firstPending))
              BackendAssistantMessage(
                id: '',
                sender: message.speaker == AssistantSpeaker.user
                    ? 'user'
                    : 'assistant',
                messageType: message.kind.name,
                text: message.text,
                payload: _messagePayload(message),
                reservationId: message.reservationId,
                action: message.action,
                createdAt: message.createdAt,
              ),
          ]);
          _persistedMessageCount = messages.length;
        }
        await state.updateAssistantConversation(
          id,
          title: _conversationTitle(),
          activeDraft: _draftPayload(),
        );
        historySaveFailed = false;
      } catch (_) {
        historySaveFailed = true;
      }
      if (!hasListeners) return;
      notifyListeners();
    });
    return _writeQueue;
  }

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

  String _formatCount(int value) {
    final raw = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      if (i > 0 && (raw.length - i) % 3 == 0) out.write(',');
      out.write(raw[i]);
    }
    return out.toString();
  }

  int _largestAllowedHeadcount(AppState state) {
    var largest = 0;
    for (final facility in state.bookableFacilities) {
      if (facility.capacity > largest) largest = facility.capacity;
    }
    if (largest == 0) largest = 5000;
    return largest > 5000 ? 5000 : largest;
  }

  _HeadcountParse _parseHeadcountText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const _HeadcountParse(problem: _HeadcountProblem.missing);
    }
    if (RegExp(r'(^|[^\w])-+\s*\d').hasMatch(trimmed)) {
      return const _HeadcountParse(problem: _HeadcountProblem.negative);
    }
    if (RegExp(r'\d+\s*\.\s*\d+').hasMatch(trimmed)) {
      return const _HeadcountParse(problem: _HeadcountProblem.fractional);
    }
    final matches = RegExp(r'\d[\d,]*').allMatches(trimmed).toList();
    if (matches.isEmpty) {
      return const _HeadcountParse(problem: _HeadcountProblem.missing);
    }
    if (matches.length > 1) {
      return const _HeadcountParse(problem: _HeadcountProblem.ambiguous);
    }
    final token = matches.single.group(0)!;
    if (token.contains(',') && !RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(token)) {
      return const _HeadcountParse(problem: _HeadcountProblem.fractional);
    }
    final value = int.tryParse(token.replaceAll(',', ''));
    if (value == null) {
      return const _HeadcountParse(problem: _HeadcountProblem.invalid);
    }
    return _HeadcountParse(value: value);
  }

  _StageInputResult _acceptHeadcount(int value, AppState state) {
    final facility = draft.facility;
    if (value < 1) {
      _say(
        'Enter at least 1 person for the booking.',
        tone: AdvisoryTone.block,
      );
      draft.heads = null;
      return _StageInputResult.rejected;
    }
    if (facility != null && value > facility.capacity) {
      _say(
        '${_formatCount(value)} people exceeds ${facility.name}\'s capacity '
        'of ${_formatCount(facility.capacity)}. Enter 1-${_formatCount(facility.capacity)}, '
        'or choose another facility.',
        tone: AdvisoryTone.block,
      );
      _suggestBiggerFacilities(value, state);
      draft.heads = null;
      return _StageInputResult.rejected;
    }
    final maxWithoutFacility = _largestAllowedHeadcount(state);
    if (facility == null && value > maxWithoutFacility) {
      _say(
        '${_formatCount(value)} people exceeds the largest currently bookable '
        'facility capacity of ${_formatCount(maxWithoutFacility)}. Enter '
        '1-${_formatCount(maxWithoutFacility)}, or lower the attendee count.',
        tone: AdvisoryTone.block,
      );
      draft.heads = null;
      return _StageInputResult.rejected;
    }
    draft.heads = value;
    return _StageInputResult.accepted;
  }

  _StageInputResult _acceptHeadcountText(String raw, AppState state) {
    final parsed = _parseHeadcountText(raw);
    if (parsed.value != null) {
      return _acceptHeadcount(parsed.value!, state);
    }
    final message = switch (parsed.problem) {
      _HeadcountProblem.negative =>
        'Attendee count cannot be negative. Enter a whole number, like 25.',
      _HeadcountProblem.fractional => 'Use a whole number of people, like 25.',
      _HeadcountProblem.ambiguous =>
        'I saw more than one number. Enter just the attendee count, like 25.',
      _HeadcountProblem.missing =>
        'Enter the attendee count as a whole number, like 25.',
      _HeadcountProblem.invalid =>
        'Enter the attendee count as a whole number, like 25.',
      null => 'Enter the attendee count as a whole number, like 25.',
    };
    _say(message, tone: AdvisoryTone.block);
    draft.heads = null;
    return _StageInputResult.rejected;
  }

  String _reservationFailureMessage(
    AppState state, {
    required String fallback,
  }) {
    final message = state.lastReservationError?.trim();
    if (message == null || message.isEmpty) return fallback;
    if (message.contains('23P01') ||
        message.toLowerCase().contains('booked') ||
        message.toLowerCase().contains('overlap')) {
      return 'That time was just booked. Choose another available slot.';
    }
    if (message.toLowerCase().contains('sign in') ||
        message.toLowerCase().contains('session')) {
      return 'Please sign in again, then retry this booking.';
    }
    if (message.toLowerCase().contains('terms')) {
      return 'Open the facility from Browse to review the current reservation terms before sending.';
    }
    return message;
  }

  void _resetDraft() {
    draft = BookingDraft();
    stage = AssistantStage.idle;
    clearActivePicker();
  }

  void toggleDraftAmenity(String label) {
    if (!draft.amenities.remove(label)) draft.amenities.add(label);
    unawaited(_queueSync());
    notifyListeners();
  }

  void removeDraftAmenity(String label) {
    draft.amenities.remove(label);
    unawaited(_queueSync());
    notifyListeners();
  }

  void syncHistory() => unawaited(_queueSync());

  void _runAction(Future<void> Function() action) {
    unawaited(_performAction(action));
  }

  Future<void> _performAction(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await action();
    } finally {
      busy = false;
      unawaited(_queueSync());
      notifyListeners();
    }
  }

  void clearActivePicker() {
    activePicker = null;
    _lastPromptKey = null;
  }

  Future<void> retryActivePicker(AppState state) async {
    final prompt = activePicker;
    if (prompt == null || busy) return;
    await _performAction(() async {
      _lastPromptKey = null;
      activePicker = null;
      switch (prompt.kind) {
        case AssistantPickerKind.facility:
          await _prepareFacilityPicker(state, force: true);
          break;
        case AssistantPickerKind.date:
          await _prepareDatePicker(state, force: true);
          break;
        case AssistantPickerKind.time:
          await _prepareTimePicker(state, force: true);
          break;
      }
    });
  }

  Future<void> selectFacility(Facility facility, AppState state) async {
    await _performAction(() async {
      messages.add(AssistantMessage.user(facility.name));
      await _ensureConversation(state);
      draft.facility = facility;
      draft.candidates = const [];
      if (draft.heads != null && draft.heads! > facility.capacity) {
        _say(
          '${_formatCount(draft.heads!)} people exceeds ${facility.name}\'s capacity '
          'of ${_formatCount(facility.capacity)}. Enter 1-${_formatCount(facility.capacity)}, '
          'or choose another facility.',
          tone: AdvisoryTone.block,
        );
        draft.heads = null;
      }
      draft.day = null;
      draft.startHour = null;
      draft.endHour = null;
      clearActivePicker();
      await _advanceDraft(state);
    });
  }

  Future<void> selectDate(DateTime date, AppState state) async {
    await _performAction(() async {
      if (await _selectDateCore(date, state, appendUserMessage: true)) {
        clearActivePicker();
        await _advanceDraft(state);
      }
    });
  }

  Future<bool> _selectDateCore(
    DateTime date,
    AppState state, {
    required bool appendUserMessage,
  }) async {
    final facility = draft.facility;
    if (facility == null) {
      return false;
    }
    final day = DateTime(date.year, date.month, date.day);
    final duration = _requestedDurationHours();
    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      _setDateErrorPrompt(facility, day, duration);
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      return false;
    }
    final slots = freeSlotsForDay(
      facility: facility,
      day: day,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      durationHours: duration,
      nowWall: campusNow(),
      limit: 1,
    );
    if (slots.isEmpty) {
      _say(
        'That date was just filled. Here are the latest available dates.',
        tone: AdvisoryTone.warn,
      );
      draft.day = null;
      draft.startHour = null;
      draft.endHour = null;
      clearActivePicker();
      await _prepareDatePicker(state, force: true);
      return false;
    }
    if (appendUserMessage) {
      messages.add(AssistantMessage.user(formatCampusDate(day)));
      await _ensureConversation(state);
    }
    draft.day = day;
    draft.startHour = null;
    draft.endHour = null;
    return true;
  }

  Future<void> selectTime(
    double startHour,
    double endHour,
    AppState state,
  ) async {
    await _performAction(() async {
      if (await _selectTimeCore(
        startHour,
        endHour,
        state,
        appendUserMessage: true,
      )) {
        clearActivePicker();
        await _advanceDraft(state);
      }
    });
  }

  Future<bool> _selectTimeCore(
    double startHour,
    double endHour,
    AppState state, {
    required bool appendUserMessage,
  }) async {
    final facility = draft.facility;
    final day = draft.day;
    if (facility == null || day == null) {
      return false;
    }
    if (!_isHalfHour(startHour) || !_isHalfHour(endHour)) {
      _say(
        'Choose times on the 30-minute grid, like 09:00-11:00 or 09:30-11:30.',
        tone: AdvisoryTone.block,
      );
      return false;
    }
    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      _setTimeErrorPrompt(facility, day);
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      return false;
    }
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: startHour,
      endHour: endHour,
      heads: draft.heads ?? 1,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!verdict.ok) {
      await _emitIssues(verdict, state, facility, day);
      return false;
    }
    if (appendUserMessage) {
      messages.add(
        AssistantMessage.user(
          '${formatClockHour(startHour)}–${formatClockHour(endHour)}',
        ),
      );
      await _ensureConversation(state);
    }
    draft.startHour = startHour;
    draft.endHour = endHour;
    return true;
  }

  Future<void> send(String text, AppState state) async {
    _state = state;
    final trimmed = text.trim();
    if (trimmed.isEmpty || busy) return;
    messages.add(AssistantMessage.user(trimmed));
    busy = true;
    notifyListeners();
    try {
      await _ensureConversation(state);
      final parsed = parseMessage(trimmed, nowWall: campusNow());
      await _handle(parsed, state);
    } finally {
      busy = false;
      unawaited(_queueSync());
      notifyListeners();
    }
  }

  Future<void> _handle(ParsedMessage p, AppState state) async {
    if (p.abort) {
      _resetDraft();
      _say('Okay, dropped that. What next?');
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
        final result = _mergeSlots(p, state);
        if (result == _StageInputResult.rejected) return;
        if (!await _validateMergedScheduling(state)) return;
        await _advanceDraft(state);
        return;
      }
    } else if (stage != AssistantStage.idle) {
      if (stage == AssistantStage.needDate && p.date != null) {
        if (p.date!.invalid || p.date!.day == null) {
          _say('That date doesn\'t look right — try something like "Aug 20".');
          return;
        }
        if (await _selectDateCore(
          p.date!.day!,
          state,
          appendUserMessage: false,
        )) {
          clearActivePicker();
          await _advanceDraft(state);
        }
        return;
      }
      if (stage == AssistantStage.needTime && p.time != null) {
        final start = p.time!.startHour;
        if (start == null) {
          _say('I need a start time, like 09:00 or 09:30.');
          return;
        }
        final end = p.time!.endHour ?? start + 2;
        if (p.time!.endHour == null) {
          _say('Assuming 2 hours — say "3 hours" to change it.');
        }
        if (await _selectTimeCore(
          start,
          end,
          state,
          appendUserMessage: false,
        )) {
          clearActivePicker();
          await _advanceDraft(state);
        }
        return;
      }
      final _StageInputResult result;
      if (_fillsCurrentStage(p)) {
        result = _mergeSlots(p, state);
      } else {
        result = _applyStageScopedFallback(p, state);
      }
      if (result == _StageInputResult.rejected) return;
      if (!await _validateMergedScheduling(state)) return;
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
        final result = _mergeSlots(p, state);
        if (result == _StageInputResult.rejected) return;
        if (!await _validateMergedScheduling(state)) return;
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

  _StageInputResult _mergeSlots(ParsedMessage p, AppState state) {
    var result = _StageInputResult.accepted;
    if (p.capacity != null) {
      final n = p.capacity!.max ?? p.capacity!.min;
      final headcountResult = _acceptHeadcount(n, state);
      if (headcountResult == _StageInputResult.rejected) {
        return headcountResult;
      }
    }

    if (p.date != null) {
      if (p.date!.invalid) {
        _say('That date doesn\'t look right — try something like "Aug 20".');
        result = _StageInputResult.rejected;
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
      final accepted = draft.facility == null
          ? p.amenities
          : normalizeRequestedAmenityLabels(draft.facility!, p.amenities)
                .toSet();
      final newOnes = accepted.difference(draft.amenities);
      draft.amenities.addAll(accepted);
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
    if (result == _StageInputResult.rejected) return result;
    if (draft.facility == null && wantsFacilitySearch) {
      result = _resolveFacility(p, state);
    } else if (p.ordinal != null && draft.candidates.isNotEmpty) {
      final index = p.ordinal! - 1;
      if (index >= 0 && index < draft.candidates.length) {
        draft.facility = draft.candidates[index];
        draft.candidates = const [];
      } else {
        result = _StageInputResult.rejected;
      }
    }
    return result;
  }

  _StageInputResult _resolveFacility(ParsedMessage p, AppState state) {
    final pool = state.bookableFacilities;
    if (pool.isEmpty) {
      _say("Give me a second — I'm still loading the campus list.");
      return _StageInputResult.rejected;
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
        return tied.length == 1
            ? _StageInputResult.accepted
            : _StageInputResult.needsSelection;
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
        return _StageInputResult.needsSelection;
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
      return _StageInputResult.rejected;
    }
    return draft.facility == null
        ? _StageInputResult.needsSelection
        : _StageInputResult.accepted;
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

  Future<bool> _validateMergedScheduling(AppState state) async {
    final facility = draft.facility;
    final day = draft.day;
    final start = draft.startHour;
    final end = draft.endHour;
    if (facility == null || day == null || start == null || end == null) {
      return true;
    }
    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      stage = AssistantStage.needTime;
      _setTimeErrorPrompt(facility, day);
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      return false;
    }
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: start,
      endHour: end,
      heads: draft.heads ?? 1,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (verdict.ok) return true;
    draft.startHour = null;
    draft.endHour = null;
    await _emitIssues(verdict, state, facility, day);
    stage = draft.firstMissing;
    return false;
  }

  _StageInputResult _applyStageScopedFallback(ParsedMessage p, AppState state) {
    switch (stage) {
      case AssistantStage.needFacility:
        if (draft.candidates.isNotEmpty && p.ordinal != null) {
          final index = p.ordinal! - 1;
          if (index >= 0 && index < draft.candidates.length) {
            draft.facility = draft.candidates[index];
            draft.candidates = const [];
            return _StageInputResult.accepted;
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
          return tied.length == 1
              ? _StageInputResult.accepted
              : _StageInputResult.needsSelection;
        } else {
          _say(
            'I still don\'t recognise that facility. Try a shorter name, like "auditorium".',
          );
          return _StageInputResult.rejected;
        }
      case AssistantStage.needPurpose:
        final text = p.raw.trim();
        if (text.length >= 3) {
          draft.purpose = text.length > 280 ? text.substring(0, 280) : text;
          return _StageInputResult.accepted;
        } else {
          _say("A few words is enough — what's the event or activity?");
          return _StageInputResult.rejected;
        }
      case AssistantStage.needHeads:
        return _acceptHeadcountText(p.raw, state);
      case AssistantStage.needDate:
      case AssistantStage.needTime:
      case AssistantStage.confirming:
      case AssistantStage.idle:
      case AssistantStage.submitting:
        _say("I didn't catch that — could you say it differently?");
        return _StageInputResult.rejected;
    }
  }

  Future<void> _advanceDraft(AppState state) async {
    if (draft.facility == null && draft.candidates.isNotEmpty) {
      stage = AssistantStage.needFacility;
      await _prepareFacilityPicker(state);
      return;
    }

    stage = draft.firstMissing;
    switch (stage) {
      case AssistantStage.needFacility:
        await _prepareFacilityPicker(state);
        break;
      case AssistantStage.needDate:
        await _prepareDatePicker(state);
        break;
      case AssistantStage.needTime:
        await _prepareTimePicker(state);
        break;
      case AssistantStage.needHeads:
        clearActivePicker();
        _say('About how many people?');
        break;
      case AssistantStage.needPurpose:
        clearActivePicker();
        _say(
          "What's it for? One sentence is enough — the assigned administrator reads this.",
        );
        break;
      case AssistantStage.confirming:
        clearActivePicker();
        await _renderConfirmCard(state);
        break;
      case AssistantStage.idle:
      case AssistantStage.submitting:
        clearActivePicker();
        break;
    }
  }

  double _requestedDurationHours() {
    if (draft.startHour != null &&
        draft.endHour != null &&
        draft.endHour! > draft.startHour!) {
      return draft.endHour! - draft.startHour!;
    }
    return 2.0;
  }

  bool _isHalfHour(double hour) => ((hour * 2).round() - hour * 2).abs() < .001;

  void _sayStageQuestion(String text) {
    final latest = messages.isEmpty ? null : messages.last;
    if (latest?.speaker == AssistantSpeaker.assistant &&
        latest?.text == text &&
        latest?.kind == AssistantMessageKind.text) {
      return;
    }
    _say(text);
  }

  int _nextPickerRevision() => ++_pickerRevision;

  Future<void> _prepareFacilityPicker(
    AppState state, {
    bool force = false,
  }) async {
    final minCapacity = draft.heads ?? 0;
    final candidateIds = draft.candidates.map((f) => f.id).join(',');
    final key =
        'facility|$minCapacity|${draft.amenities.join(',')}|$candidateIds|'
        '${draft.day == null ? '' : dayKey(draft.day!)}|'
        '${draft.startHour ?? ''}|${draft.endHour ?? ''}';
    if (!force && _lastPromptKey == key && activePicker != null) return;

    _sayStageQuestion('Which facility works for you?');
    var matches = draft.candidates.isNotEmpty
        ? draft.candidates
        : state.searchFacilities(
            minCapacity: minCapacity,
            amenities: draft.amenities,
            category: 'All categories',
          );

    final day = draft.day;
    final start = draft.startHour;
    final end = draft.endHour;
    if (day != null && start != null && end != null && matches.isNotEmpty) {
      final snapshot = await state.availabilitySnapshotFor(
        matches,
        fromWall: day,
        toWall: day.add(const Duration(days: 1)),
        forceRefresh: true,
      );
      if (!snapshot.isTrusted) {
        _lastPromptKey = key;
        activePicker = FacilityPickerPrompt(
          revision: _nextPickerRevision(),
          status: AssistantPickerStatus.error,
          title: 'Live schedule unavailable',
          subtitle: 'I need the live schedule before offering rooms.',
          recommended: const [],
          allMatches: matches,
          error: 'Please retry when the schedule can be checked.',
        );
        return;
      }
      matches = [
        for (final facility in matches)
          if (checkSlot(
            facility: facility,
            day: day,
            startHour: start,
            endHour: end,
            heads: draft.heads ?? 1,
            busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
            nowWall: campusNow(),
          ).ok)
            facility,
      ];
    }

    _lastPromptKey = key;
    activePicker = FacilityPickerPrompt(
      revision: _nextPickerRevision(),
      status: matches.isEmpty
          ? AssistantPickerStatus.empty
          : AssistantPickerStatus.ready,
      title: 'Choose a facility',
      subtitle: matches.isEmpty
          ? 'No bookable facility matches the current filters.'
          : 'Pick one of these, or browse every match.',
      recommended: matches.take(3).toList(),
      allMatches: matches,
      error: matches.isEmpty
          ? 'Try changing the facility, attendee count, or amenities.'
          : null,
    );
  }

  Future<void> _prepareDatePicker(AppState state, {bool force = false}) async {
    final facility = draft.facility;
    if (facility == null) return;
    final now = campusNow();
    final today = DateTime(now.year, now.month, now.day);
    final lastDate = today.add(Duration(days: facility.advanceBookingDays));
    final duration = _requestedDurationHours();
    final key =
        'date|${facility.id}|${dayKey(today)}|${duration.toStringAsFixed(2)}';
    if (!force && _lastPromptKey == key && activePicker != null) return;

    _sayStageQuestion('Choose a date for ${facility.name}.');
    final revision = _nextPickerRevision();
    _lastPromptKey = key;
    activePicker = DatePickerPrompt(
      revision: revision,
      status: AssistantPickerStatus.loading,
      title: 'Choose a date',
      subtitle: 'Scanning the live schedule for ${facility.name}.',
      recommended: const [],
      availableDays: const {},
      firstDate: today,
      lastDate: lastDate,
      requiredDurationHours: duration,
    );
    notifyListeners();

    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: today,
      toWall: lastDate.add(const Duration(days: 1)),
      forceRefresh: force,
    );
    if (!snapshot.isTrusted) {
      _setDateErrorPrompt(facility, today, duration, revision: revision);
      return;
    }
    final days = availableBookingDaysForFacility(
      facility: facility,
      fromWall: today,
      toWall: lastDate,
      busy: snapshot.windows,
      durationHours: duration,
      nowWall: now,
    );
    activePicker = DatePickerPrompt(
      revision: revision,
      status: days.isEmpty
          ? AssistantPickerStatus.empty
          : AssistantPickerStatus.ready,
      title: 'Choose a date',
      subtitle: days.isEmpty
          ? 'No two-hour opening is available within this facility\'s booking window.'
          : 'These are the earliest dates with at least one open slot.',
      recommended: days.take(3).toList(),
      availableDays: {
        for (final item in days)
          DateTime(item.day.year, item.day.month, item.day.day),
      },
      firstDate: today,
      lastDate: lastDate,
      requiredDurationHours: duration,
      error: days.isEmpty ? 'Change facility or retry the live scan.' : null,
    );
  }

  Future<void> _prepareTimePicker(AppState state, {bool force = false}) async {
    final facility = draft.facility;
    final day = draft.day;
    if (facility == null || day == null) return;
    final duration = _requestedDurationHours();
    final key =
        'time|${facility.id}|${dayKey(day)}|${duration.toStringAsFixed(2)}';
    if (!force && _lastPromptKey == key && activePicker != null) return;

    _sayStageQuestion('Choose an available time on ${formatCampusDate(day)}.');
    final revision = _nextPickerRevision();
    _lastPromptKey = key;
    activePicker = TimePickerPrompt(
      revision: revision,
      status: AssistantPickerStatus.loading,
      title: 'Choose a time',
      subtitle: 'Refreshing ${facility.name} for ${formatCampusDate(day)}.',
      recommended: const [],
      allSlots: const [],
      busyWindows: const [],
      openHour: facility.openHour,
      closeHour: facility.closeHour,
      maxDurationMinutes: facility.maxDurationMinutes,
      bufferMinutes: facility.bookingBufferMinutes,
      day: day,
      requiredDurationHours: duration,
    );
    notifyListeners();

    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      _setTimeErrorPrompt(facility, day, revision: revision);
      return;
    }
    final windows =
        snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [];
    final slots = freeSlotsForDay(
      facility: facility,
      day: day,
      busy: windows,
      durationHours: duration,
      nowWall: campusNow(),
      limit: 200,
    );
    if (slots.isEmpty) {
      _say(
        '${facility.name} just became fully booked on ${formatCampusDate(day)}. Choose another date.',
        tone: AdvisoryTone.warn,
      );
      draft.day = null;
      draft.startHour = null;
      draft.endHour = null;
      stage = AssistantStage.needDate;
      clearActivePicker();
      await _prepareDatePicker(state, force: true);
      return;
    }
    activePicker = TimePickerPrompt(
      revision: revision,
      status: AssistantPickerStatus.ready,
      title: 'Choose a time',
      subtitle: '${facility.name} on ${formatCampusDate(day)}.',
      recommended: slots.take(3).toList(),
      allSlots: slots,
      busyWindows: windows,
      openHour: facility.openHour,
      closeHour: facility.closeHour,
      maxDurationMinutes: facility.maxDurationMinutes,
      bufferMinutes: facility.bookingBufferMinutes,
      day: day,
      requiredDurationHours: duration,
    );
  }

  void _setDateErrorPrompt(
    Facility facility,
    DateTime _,
    double duration, {
    int? revision,
  }) {
    final now = campusNow();
    final today = DateTime(now.year, now.month, now.day);
    activePicker = DatePickerPrompt(
      revision: revision ?? _nextPickerRevision(),
      status: AssistantPickerStatus.error,
      title: 'Live schedule unavailable',
      subtitle: 'I need the live schedule before offering dates.',
      recommended: const [],
      availableDays: const {},
      firstDate: today,
      lastDate: today.add(Duration(days: facility.advanceBookingDays)),
      requiredDurationHours: duration,
      error: 'Please retry when the schedule can be checked.',
    );
  }

  void _setTimeErrorPrompt(Facility facility, DateTime day, {int? revision}) {
    activePicker = TimePickerPrompt(
      revision: revision ?? _nextPickerRevision(),
      status: AssistantPickerStatus.error,
      title: 'Live schedule unavailable',
      subtitle: 'I need the live schedule before offering times.',
      recommended: const [],
      allSlots: const [],
      busyWindows: const [],
      openHour: facility.openHour,
      closeHour: facility.closeHour,
      maxDurationMinutes: facility.maxDurationMinutes,
      bufferMinutes: facility.bookingBufferMinutes,
      day: day,
      requiredDurationHours: _requestedDurationHours(),
      error: 'Please retry when the schedule can be checked.',
    );
  }

  Future<void> _emitIssues(
    SlotVerdict verdict,
    AppState state,
    Facility facility,
    DateTime day,
  ) async {
    if (verdict.issues.isEmpty) return;
    final issue = verdict.issues.first;
    switch (issue) {
      case SlotIssue.closedDay:
        _say(
          '${facility.name} runs ${facility.days}, so ${formatCampusDate(day)} is not bookable.',
          tone: AdvisoryTone.block,
        );
        draft.day = null;
        draft.startHour = null;
        draft.endHour = null;
        break;
      case SlotIssue.outsideHours:
        _say(
          '${facility.name} runs ${facility.hours}. Choose a time inside those hours.',
          tone: AdvisoryTone.block,
        );
        draft.startHour = null;
        draft.endHour = null;
        break;
      case SlotIssue.tooLong:
        _say(
          '${facility.name} allows bookings up to ${facility.maxDuration}. Choose a shorter range.',
          tone: AdvisoryTone.block,
        );
        draft.startHour = null;
        draft.endHour = null;
        break;
      case SlotIssue.inPast:
        _say(
          'That time has already passed. Choose a future date and time.',
          tone: AdvisoryTone.block,
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
          'Bookings for ${facility.name} open only ${facility.advanceBookingDays} days ahead. '
          'The furthest available date is ${formatCampusDate(limit)}.',
          tone: AdvisoryTone.block,
        );
        draft.day = null;
        draft.startHour = null;
        draft.endHour = null;
        break;
      case SlotIssue.overCapacity:
        final heads = draft.heads;
        _say(
          heads == null
              ? '${facility.name} seats ${_formatCount(facility.capacity)}. Enter 1-${_formatCount(facility.capacity)}, or choose another facility.'
              : '${_formatCount(heads)} people exceeds ${facility.name}\'s capacity of ${_formatCount(facility.capacity)}. Enter 1-${_formatCount(facility.capacity)}, or choose another facility.',
          tone: AdvisoryTone.block,
        );
        _suggestBiggerFacilities((draft.heads ?? facility.capacity) + 1, state);
        draft.heads = null;
        break;
      case SlotIssue.clash:
        state.invalidateBusyCache(facility.id, day);
        _say(
          'That time was just taken. Here are the latest available times.',
          tone: AdvisoryTone.warn,
        );
        draft.startHour = null;
        draft.endHour = null;
        break;
      case SlotIssue.facilityUnavailable:
        _say(
          '${facility.name} is closed for maintenance right now. Choose another facility.',
          tone: AdvisoryTone.block,
        );
        draft.facility = null;
        draft.day = null;
        draft.startHour = null;
        draft.endHour = null;
        break;
      case SlotIssue.zeroDuration:
        _say(
          "That end time isn't after the start. Choose a valid time range.",
          tone: AdvisoryTone.block,
        );
        draft.startHour = null;
        draft.endHour = null;
        break;
    }
    final needsTimePicker = verdict.issues.any(
      (issue) => {
        SlotIssue.clash,
        SlotIssue.outsideHours,
        SlotIssue.tooLong,
        SlotIssue.zeroDuration,
      }.contains(issue),
    );
    final needsDatePicker = verdict.issues.any(
      (issue) => {
        SlotIssue.closedDay,
        SlotIssue.inPast,
        SlotIssue.beyondAdvance,
      }.contains(issue),
    );
    if (needsTimePicker && draft.facility != null && draft.day != null) {
      await _prepareTimePicker(state, force: true);
    } else if (needsDatePicker && draft.facility != null) {
      await _prepareDatePicker(state, force: true);
    }
  }

  Future<void> _renderConfirmCard(AppState state) async {
    final facility = draft.facility!;
    final day = draft.day!;
    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      stage = AssistantStage.needTime;
      _setTimeErrorPrompt(facility, day);
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      return;
    }
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: draft.startHour!,
      endHour: draft.endHour!,
      heads: draft.heads!,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!verdict.ok) {
      draft.startHour = null;
      draft.endHour = null;
      await _emitIssues(verdict, state, facility, day);
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

    var snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      stage = AssistantStage.needTime;
      _setTimeErrorPrompt(facility, day);
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      notifyListeners();
      return;
    }
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: startHour,
      endHour: endHour,
      heads: heads,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!verdict.ok) {
      draft.startHour = null;
      draft.endHour = null;
      await _emitIssues(verdict, state, facility, day);
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

    final requestedAmenities = normalizeRequestedAmenityLabels(
      facility,
      draft.amenities,
    );
    final quote = await state.quoteReservation(
      facility: facility,
      startsAt: [campusInstant(startWall)],
      endsAt: [campusInstant(endWall)],
      headcount: heads,
    );
    if (quote == null || quote.terms.isNotEmpty) {
      _submitting = false;
      stage = AssistantStage.confirming;
      _say(
        quote == null
            ? _reservationFailureMessage(
                state,
                fallback:
                    'The price could not be calculated. Please retry before sending.',
              )
            : 'Open ${facility.name} from Browse to review the exact price and accept the current terms before sending.',
        tone: quote == null ? AdvisoryTone.block : AdvisoryTone.info,
      );
      notifyListeners();
      return;
    }
    snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      _submitting = false;
      stage = AssistantStage.needTime;
      _setTimeErrorPrompt(facility, day);
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      notifyListeners();
      return;
    }
    final submitVerdict = checkSlot(
      facility: facility,
      day: day,
      startHour: startHour,
      endHour: endHour,
      heads: heads,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!submitVerdict.ok) {
      _submitting = false;
      draft.facility = facility;
      draft.day = day;
      draft.startHour = null;
      draft.endHour = null;
      draft.heads = heads;
      draft.purpose = purpose;
      _say(
        'That time was just taken. Here are the latest available times.',
        tone: AdvisoryTone.warn,
      );
      stage = AssistantStage.needTime;
      await _prepareTimePicker(state, force: true);
      notifyListeners();
      return;
    }
    final ok = await state.submitReservationRequest(
      facility: facility,
      startsAt: [campusInstant(startWall)],
      endsAt: [campusInstant(endWall)],
      heads: heads,
      purpose: purpose.trim(),
      requestedAmenities: requestedAmenities,
      quote: quote,
      acceptedTerms: true,
    );

    _submitting = false;
    state.invalidateBusyCache(facility.id, day);

    if (ok) {
      ReservationRequest? submitted;
      for (final request in state.myRequests) {
        if (request.facility == facility.name && request.purpose == purpose) {
          submitted = request;
          break;
        }
      }
      _say(
        'Sent. ${facility.name}, ${formatCampusDate(day)} '
        '${formatClockHour(startHour)}–${formatClockHour(endHour)}. '
        'The assigned ${quote.adminLane} administrator will decide — check My reservations for updates.'
        '${requestedAmenities.isEmpty ? '' : ' Requested: ${requestedAmenities.join(', ')}.'}',
      );
      messages.add(
        AssistantMessage.activity(
          'Reservation request sent · ${facility.name} · '
          '${formatCampusDate(day)} ${formatClockHour(startHour)}–${formatClockHour(endHour)}',
          reservationId: submitted?.id,
          action: 'submitted',
        ),
      );
      _resetDraft();
    } else {
      final errorMessage = _reservationFailureMessage(
        state,
        fallback:
            'The reservation could not be sent. Please retry in a moment.',
      );
      _say(errorMessage, tone: AdvisoryTone.block);
      draft.facility = facility;
      draft.day = day;
      final lower = errorMessage.toLowerCase();
      final likelySlotConflict =
          lower.contains('booked') || lower.contains('slot');
      draft.startHour = likelySlotConflict ? null : startHour;
      draft.endHour = likelySlotConflict ? null : endHour;
      draft.heads = heads;
      draft.purpose = purpose;
      if (likelySlotConflict) {
        stage = AssistantStage.needTime;
        await _prepareTimePicker(state, force: true);
      } else {
        stage = AssistantStage.confirming;
      }
    }
    unawaited(_queueSync());
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

    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      return;
    }
    final key = '${facility.id}|${dayKey(day)}';

    if (p.time?.startHour != null && p.time?.endHour != null) {
      final start = p.time!.startHour!;
      final end = p.time!.endHour!;
      final verdict = checkSlot(
        facility: facility,
        day: day,
        startHour: start,
        endHour: end,
        heads: 1,
        busy: snapshot.windows[key] ?? const [],
        nowWall: campusNow(),
      );
      if (verdict.ok) {
        _say(
          '${facility.name} is free ${formatClockHour(start)}–'
          '${formatClockHour(end)} on ${formatCampusDate(day)}.',
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
          busy: snapshot.windows[key] ?? const [],
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
        await _emitIssues(verdict, state, facility, day);
      }
      return;
    }

    final slots = freeSlotsForDay(
      facility: facility,
      day: day,
      busy: snapshot.windows[key] ?? const [],
      durationHours: duration,
      nowWall: campusNow(),
    );
    if (slots.isEmpty) {
      _say('${facility.name} looks fully booked on ${formatCampusDate(day)}.');
      return;
    }
    _say('${facility.name} is open ${formatCampusDate(day)}:');
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
    await selectFacility(facility, state);
  }

  void noteCancelled(ReservationRequest request) {
    messages.add(
      AssistantMessage.activity(
        'Reservation cancelled · ${request.facility} on ${request.whenLabel}',
        reservationId: request.id,
        action: 'cancelled',
      ),
    );
    unawaited(_queueSync());
    notifyListeners();
  }

  void discardDraft() {
    _resetDraft();
    _say('Okay, cancelled. What next?');
    unawaited(_queueSync());
    notifyListeners();
  }

  Future<void> _startBookingFromCheck(
    Facility facility,
    DateTime day,
    double start,
    double end,
    AppState state,
  ) async {
    final snapshot = await state.availabilitySnapshotFor(
      [facility],
      fromWall: day,
      toWall: day.add(const Duration(days: 1)),
      forceRefresh: true,
    );
    if (!snapshot.isTrusted) {
      _say(
        'Live schedule is unavailable. We can\'t verify this booking yet.',
        tone: AdvisoryTone.block,
      );
      return;
    }
    final verdict = checkSlot(
      facility: facility,
      day: day,
      startHour: start,
      endHour: end,
      heads: draft.heads ?? 1,
      busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
      nowWall: campusNow(),
    );
    if (!verdict.ok) {
      _say(
        'That time was just taken. Here are the latest available times.',
        tone: AdvisoryTone.warn,
      );
      draft.facility = facility;
      draft.day = day;
      draft.startHour = null;
      draft.endHour = null;
      stage = AssistantStage.needTime;
      await _prepareTimePicker(state, force: true);
      return;
    }
    messages.add(AssistantMessage.user('Yes, book it'));
    await _ensureConversation(state);
    draft.facility = facility;
    draft.day = day;
    draft.startHour = start;
    draft.endHour = end;
    clearActivePicker();
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
