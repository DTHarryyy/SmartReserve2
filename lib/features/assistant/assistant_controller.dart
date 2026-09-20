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
import '../../model/payment.dart';
import 'assistant_ai_client.dart';
import 'assistant_availability.dart';
import 'assistant_nlu.dart';
import 'assistant_recommendation.dart';
import 'assistant_reference_frame.dart';
import 'assistant_router.dart';

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

  /// An answer the cloud model phrased. Persisted under its own name so a
  /// transcript distinguishes it from a rule-written reply; the database CHECK
  /// on assistant_messages.message_type accepts it from
  /// 20260921150000_assistant_ai_foundation.sql onward.
  aiText,
  proposal,
}

/// The wire name for a message kind. `aiText` is `ai_text` in the database,
/// which is snake_case like every other value in that CHECK constraint.
extension AssistantMessageKindWire on AssistantMessageKind {
  String get wireName => switch (this) {
    AssistantMessageKind.aiText => 'ai_text',
    _ => name,
  };

  static AssistantMessageKind fromWire(String value) => switch (value) {
    'ai_text' => AssistantMessageKind.aiText,
    _ => AssistantMessageKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => AssistantMessageKind.text,
    ),
  };
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
    this.assisted = false,
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

  /// True when a cloud model phrased this answer. Stored and rendered so a
  /// transcript can be audited for what the model actually said.
  final bool assisted;
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
    bool assisted = false,
  }) => AssistantMessage._(
    speaker: AssistantSpeaker.assistant,
    kind: assisted
        ? AssistantMessageKind.aiText
        : AssistantMessageKind.text,
    text: text,
    tone: tone,
    reservationId: reservationId,
    action: action,
    assisted: assisted,
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
  AssistantController({AssistantAiClient? aiClient}) {
    _aiClient = aiClient;
    _seedGreeting();
  }

  /// Null until an AI client is attached. While it is null the assistant
  /// behaves exactly as it did before this feature existed, which is also the
  /// behaviour every test without a client exercises.
  AssistantAiClient? _aiClient;

  set aiClient(AssistantAiClient? value) => _aiClient = value;

  /// Model-assisted turns spent on the stage the draft is currently waiting
  /// on. Reset whenever the stage moves, so the cap is per question rather
  /// than per conversation.
  int _assistsForStage = 0;
  AssistantStage? _assistStage;

  /// A rolling precis of the turns that have fallen out of the replayed
  /// window, produced by the model on the same call that answered and sent
  /// back on the next one.
  ///
  /// Held here rather than re-read from the database each turn: it is the
  /// server's own output coming straight back, and a read would cost a round
  /// trip to learn something we were just told.
  String? _contextSummary;

  /// Set when the last turn fell back to rules because the service was
  /// unavailable, so the UI can say so once rather than on every message.
  bool aiDegraded = false;

  /// Test seam for the degraded banner. Reaching this state for real needs a
  /// failing provider behind a whole model turn, which is a lot of scaffolding
  /// to assert that one notice appears.
  @visibleForTesting
  void debugSetAiDegraded(bool value) {
    aiDegraded = value;
    notifyListeners();
  }

  static const _greeting =
      'Hi! Ask me to find a room, check if a time is free, or book one '
      'right here — for example "book a room for 50 people next Thursday '
      '2 to 4pm".';

  final List<AssistantMessage> messages = [];
  final List<BackendAssistantConversation> conversations = [];

  /// What "this one" and "the second one" currently point at. Updated whenever
  /// a list or detail card is rendered, so follow-ups resolve in Dart rather
  /// than being guessed downstream.
  final AssistantReferenceFrame frame = AssistantReferenceFrame();
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
    // A newly opened chat page is a new session. Finish saving the session the
    // user just left, but never restore it implicitly; saved chats remain
    // available from Chat history when the user explicitly chooses one.
    if (freshVisit && _accountId == accountId) await _queueSync();
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
    // Belongs to the conversation being left behind, not the one being opened.
    _contextSummary = null;
    _persistedMessageCount = 0;
    draft = BookingDraft();
    stage = AssistantStage.idle;
    clearActivePicker();
    notifyListeners();
    try {
      if (state.assistantHistoryAvailable) {
        conversations.addAll(await state.assistantConversations());
        if (!freshVisit) {
          final resumable = conversations
              .where(
                (conversation) => _isResumableDraft(conversation.activeDraft),
              )
              .firstOrNull;
          if (resumable != null) {
            await _loadConversation(resumable, state);
            return;
          }
        }
      }
      _startLocalConversation();
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
    _contextSummary = null;
    frame.clear();
    _assistsForStage = 0;
    _assistStage = null;
    aiDegraded = false;
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
    final kind = AssistantMessageKindWire.fromWire(message.messageType);
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
      // The stored kind is what makes a reloaded transcript still show which
      // answers a model wrote. Without this, reopening a conversation would
      // quietly relabel them as rule-written.
      assisted: kind == AssistantMessageKind.aiText,
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
                messageType: message.kind.wireName,
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
      return 'Review and accept the current reservation terms before sending — your details are carried over.';
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
      // Mid-booking, the stage machine owns the conversation. The model is
      // consulted only when neither the slot parser nor the stage's own
      // fallback can read the reply -- "sa makalawa siguro, tanghali" -- and
      // even then it only proposes a value, which is validated below exactly
      // like a typed or tapped one. A bare "30" at the headcount stage is read
      // deterministically and costs nothing.
      if (!_fillsCurrentStage(p) &&
          !_deterministicCanFillStage(p, state) &&
          _routeFor(p, state).reason ==
              EscalationReason.unparsedBookingSlot) {
        if (await _assistCurrentStage(p, state)) return;
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

    // Outside a booking, anything the parser could not classify is where the
    // model earns its place. Everything it did classify already has a rule
    // handler below, and those cost nothing.
    if (p.intent == AssistantIntent.unknown) {
      final route = _routeFor(p, state);
      if (route.isEscalation && await _answerWithAi(p, state)) return;
    }

    switch (p.intent) {
      case AssistantIntent.findFacilities:
        if (await _tryDiscoveryAi(p, state)) return;
        _handleFindFacilities(p, state);
        break;
      case AssistantIntent.checkAvailability:
        if (await _tryDiscoveryAi(p, state)) return;
        await _handleCheckAvailability(p, state);
        break;
      case AssistantIntent.book:
        // A booking whose facility the rules cannot pin down is exactly the
        // "phrasing no rule covers" case the model exists for. Everything the
        // parser did resolve still takes the free path below.
        if (_routeFor(p, state).reason ==
                EscalationReason.unresolvedFacilityRequest &&
            await _answerWithAi(p, state)) {
          return;
        }
        final result = _mergeSlots(p, state);
        if (result == _StageInputResult.rejected) return;
        if (!await _validateMergedScheduling(state)) return;
        await _advanceDraft(state);
        break;
      case AssistantIntent.myReservations:
        _handleMyReservations(state);
        break;
      case AssistantIntent.cancel:
        _handleCancelRequest(p, state);
        break;
      case AssistantIntent.recommendFacility:
        if (await _tryDiscoveryAi(p, state)) return;
        _handleRecommendFacility(p, state);
        break;
      case AssistantIntent.reservationStatus:
        _handleReservationStatus(p, state);
        break;
      case AssistantIntent.paymentBalance:
      case AssistantIntent.paymentDeadline:
        _handlePayment(p, state);
        break;
      case AssistantIntent.permitStatus:
        await _handlePermitStatus(p, state);
        break;
      case AssistantIntent.permitRequirements:
        _handlePermitRequirements();
        break;
      case AssistantIntent.equipment:
        _handleEquipment(p, state);
        break;
      case AssistantIntent.announcements:
        _handleAnnouncements(state);
        break;
      case AssistantIntent.policyFaq:
        await _handlePolicyFaq(p, state);
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

  // ---------------------------------------------------------------------------
  // Cloud-model escalation.
  //
  // Every method here returns false when it could not help, and the caller
  // then answers the deterministic way. That is the whole contract: the AI
  // layer can only ever improve a turn, never take one away.
  // ---------------------------------------------------------------------------

  AssistantRoute _routeFor(ParsedMessage p, AppState state) => routeMessage(
    p,
    context: AssistantRouteContext(
      inBookingFlow:
          stage != AssistantStage.idle && stage != AssistantStage.submitting,
      stageAccepted: _fillsCurrentStage(p),
      assistsUsedForStage: _assistStage == stage ? _assistsForStage : 0,
      // Having a client is the whole test: one is only attached when a real
      // backend exists, and the client itself reports unavailability rather
      // than throwing. Re-checking the backend here would duplicate that
      // decision in a second place.
      aiAvailable: _aiClient != null,
      facilityRequestUnresolved: _facilityRequestUnresolved(p, state),
      facilityResolved: _resolvesToOneFacility(p, state),
      referenceFrame: frame,
    ),
  );

  /// True when the message names exactly one bookable facility.
  ///
  /// This is the test for "the rules can answer this precisely": with one
  /// facility and a date, `_handleCheckAvailability` reads the live schedule
  /// and states the free windows, which no model improves on. Without it, the
  /// same handler can only ask "Which one?" and print the catalogue.
  bool _resolvesToOneFacility(ParsedMessage p, AppState state) {
    if (draft.facility != null) return true;
    final query = p.facilityQuery;
    if (query == null || query.isEmpty) return false;
    return _tiedTop(
          resolveFacilityByName(query, state.bookableFacilities),
        ).length ==
        1;
  }

  /// True when the user described a facility we cannot resolve at all.
  ///
  /// Deliberately narrow. A bare "book a room" describes nothing, so it stays
  /// on the free path and keeps opening the picker; only a request carrying a
  /// descriptor the catalogue cannot account for is worth a model call.
  bool _facilityRequestUnresolved(ParsedMessage p, AppState state) {
    if (draft.facility != null) return false;
    if (p.activity == null && p.facilityQuery == null) return false;
    if (p.category != null || p.capacity != null || p.amenities.isNotEmpty) {
      return false;
    }
    final pool = state.bookableFacilities;
    if (pool.isEmpty) return false;
    return resolveFacilityByName(p.facilityQuery ?? p.raw, pool).isEmpty;
  }

  /// The model's attempt at a "what should I book" question.
  ///
  /// False means the caller should answer it the deterministic way, and every
  /// caller does. That covers a routing decision that did not escalate, no
  /// client at all, a client that threw, a disabled or rate-limited service
  /// and an empty reply -- `_answerWithAi` collapses all of them to false.
  Future<bool> _tryDiscoveryAi(ParsedMessage p, AppState state) async {
    if (_routeFor(p, state).reason != EscalationReason.discovery) return false;
    return _answerWithAi(p, state);
  }

  /// Ask the model, surviving a client that misbehaves.
  ///
  /// The supplied client swallows its own failures, but the controller must
  /// not depend on that: a chat turn is never allowed to fail because an
  /// optional enhancement did.
  Future<AssistantAiReply> _askAi(
    AssistantAiClient client,
    AssistantAiRequest request,
  ) async {
    try {
      return await client.ask(request);
    } catch (_) {
      return AssistantAiReply.unavailable;
    }
  }

  AssistantAiRequest _aiRequestFor(ParsedMessage p, AppState state) =>
      AssistantAiRequest(
        message: p.raw,
        conversationId: conversationId,
        history: [
          for (final message in messages.reversed.take(6).toList().reversed)
            if (message.text.trim().isNotEmpty)
              (
                role: message.speaker == AssistantSpeaker.user
                    ? 'user'
                    : 'assistant',
                content: message.text,
              ),
        ],
        summary: _contextSummary,
        // The whole conversation, not the six turns being replayed. The server
        // only asks the model to keep a summary once this outgrows the window.
        turnCount: messages.length,
        frame: frame,
        inBookingFlow:
            stage != AssistantStage.idle && stage != AssistantStage.submitting,
        bookingDraft: stage == AssistantStage.idle ? null : _draftStatePayload(),
      );

  /// What the model is told about the in-progress booking.
  ///
  /// The limits travel with it so a follow-up question can be grounded --
  /// asking for a headcount without knowing the capacity produces a question
  /// the user then has to be corrected on.
  Map<String, dynamic> _draftStatePayload() {
    final facility = draft.facility;
    return {
      'stage': stage.name,
      'missing_slot': draft.firstMissing.name,
      if (facility != null)
        'facility': {
          'id': facility.id,
          'name': facility.name,
          'capacity': facility.capacity,
          'open_hour': facility.openHour,
          'close_hour': facility.closeHour,
          'days': facility.days,
          'max_duration_minutes': facility.maxDurationMinutes,
          'advance_booking_days': facility.advanceBookingDays,
        },
      if (draft.day != null) 'day': dayKey(draft.day!),
      if (draft.startHour != null) 'start_hour': draft.startHour,
      if (draft.endHour != null) 'end_hour': draft.endHour,
      if (draft.heads != null) 'heads': draft.heads,
      if (draft.purpose != null) 'purpose': draft.purpose,
    };
  }

  /// Answer an unclassifiable question with the model. Returns false when the
  /// caller should use the deterministic reply instead.
  Future<bool> _answerWithAi(ParsedMessage p, AppState state) async {
    final client = _aiClient;
    if (client == null) return false;

    final reply = await _askAi(client, _aiRequestFor(p, state));
    _rememberSummary(reply);
    if (!reply.hasText) {
      aiDegraded = reply.degraded && reply.failureCode != 'disabled';
      return false;
    }

    aiDegraded = false;
    messages.add(
      AssistantMessage.assistant(reply.text!, assisted: true),
    );

    // A proposal is an offer, never an action. It is re-validated here against
    // the same rules a tapped or typed request would face, and then rendered
    // as something the user has to confirm.
    final proposal = reply.proposal;
    if (proposal != null && await _renderProposal(proposal, state)) {
      return true;
    }

    // The model is told to answer a facility question in one sentence and let
    // the app show the matches as cards -- resolve the ids it named against
    // what this user may actually book. An id that does not resolve (stale,
    // or from a facility this user cannot book) is simply dropped; nothing
    // else about the reply changes.
    //
    // The model ranked these ids, and the sentence above the cards refers to
    // that order -- "the Gymplex is the closest" reads as a lie if the
    // Gymplex is third. Indexing rather than scanning the catalogue per id is
    // what preserves it.
    final byId = {for (final f in state.bookableFacilities) f.id: f};
    final matches = [
      for (final id in reply.facilityIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (matches.isNotEmpty) {
      if (matches.length == 1) {
        // One suggestion is a decision, not a menu: "yes, book that" on the
        // next turn has to work without asking which one again.
        draft.facility = matches.first;
        draft.candidates = const [];
      } else {
        draft.candidates = matches;
      }
      // No caption: the model's own sentence is already sitting above these
      // cards, and a rule-written header over it is the duplication this
      // whole change exists to remove.
      _showFacilities(matches);
      return true;
    }

    // Always leave a next step, even after a model answer.
    messages.add(AssistantMessage.chips('', _defaultSuggestions()));
    return true;
  }

  /// Turn a model proposal into something the user can accept or ignore.
  ///
  /// Nothing is written here. A well-formed booking proposal fills the draft
  /// and either stops at the confirm card, when the exact slot still holds,
  /// or falls back to the ordinary time/date picker with the same "why"
  /// _emitIssues already gives a merged reply that stops working mid-flow --
  /// so a stale suggestion costs a turn, never a bad booking. A cancellation
  /// proposal surfaces the reservation whose own Cancel button does the work.
  /// Either way the write happens on a tap, through the paths that already
  /// carry optimistic concurrency and server-side pricing. Only a malformed
  /// proposal -- missing or wrongly-shaped fields -- returns false and
  /// changes nothing, leaving the caller to fall back to the chip menu.
  Future<bool> _renderProposal(
    Map<String, dynamic> proposal,
    AppState state,
  ) async {
    switch (proposal['kind']) {
      case 'cancellation':
        final id = '${proposal['reservation_id']}';
        final target = state.myRequests
            .where((request) => request.id == id)
            .firstOrNull;
        // Ownership and the cancellation rule are checked locally; a proposal
        // naming somebody else's booking, or one already under way, is simply
        // not rendered.
        if (target == null || !state.canCancelReservation(target)) return false;
        frame.noteReservationFocus(target.id);
        _say(
          'Tap Cancel on the card to confirm — nothing is cancelled until you do.',
          tone: AdvisoryTone.warn,
        );
        _showReservations([target]);
        return true;

      case 'booking':
        final facility = state.bookableFacilities
            .where((item) => item.id == '${proposal['facility_id']}')
            .firstOrNull;
        final day = DateTime.tryParse('${proposal['day']}');
        final start = (proposal['start_hour'] as num?)?.toDouble();
        final end = (proposal['end_hour'] as num?)?.toDouble();
        final heads = proposal['heads'];
        final purpose = '${proposal['purpose'] ?? ''}'.trim();
        // A malformed proposal -- missing or wrongly-shaped fields -- is the
        // one case that changes nothing: there is no partial draft worth
        // keeping when the model did not even send a well-formed offer.
        if (facility == null ||
            day == null ||
            start == null ||
            end == null ||
            heads is! num ||
            heads != heads.roundToDouble() ||
            purpose.length < 3) {
          return false;
        }

        // From here the proposal is well-formed; fill the draft with it so
        // that whatever the checks below reject is the only part reset --
        // the rest survives, same as a merged reply during ordinary booking.
        draft
          ..facility = facility
          ..day = day
          ..startHour = start
          ..endHour = end
          ..heads = heads.toInt()
          ..purpose = purpose;

        final snapshot = await state.availabilitySnapshotFor(
          [facility],
          fromWall: day,
          toWall: day.add(const Duration(days: 1)),
          forceRefresh: true,
        );
        // Never offer a slot we could not verify. A stale schedule is exactly
        // the case where a confident-looking suggestion does the most damage.
        if (!snapshot.isTrusted) {
          stage = AssistantStage.needTime;
          _setTimeErrorPrompt(facility, day);
          _say(
            'Live schedule is unavailable. We can\'t verify this booking yet.',
            tone: AdvisoryTone.block,
          );
          return true;
        }

        final verdict = checkSlot(
          facility: facility,
          day: day,
          startHour: start,
          endHour: end,
          heads: heads.toInt(),
          busy: snapshot.windows['${facility.id}|${dayKey(day)}'] ?? const [],
          nowWall: campusNow(),
        );
        if (!verdict.ok) {
          await _emitIssues(verdict, state, facility, day);
          stage = draft.firstMissing;
          return true;
        }

        // The slot holds. Say plainly, same as the cancellation branch above,
        // that this is a review step: the model can offer a booking, but only
        // the user's own tap on the confirm card actually sends it.
        _say(
          'Review the details below and tap Send — nothing is booked until you do.',
          tone: AdvisoryTone.info,
        );
        clearActivePicker();
        await _advanceDraft(state);
        return true;

      default:
        return false;
    }
  }

  /// Let the model read a booking reply the parser could not.
  ///
  /// It proposes a slot value, or -- when the user supplied every remaining
  /// slot in one message -- a full booking proposal that jumps straight to
  /// the confirm card. Either way the existing validators decide whether the
  /// value is allowed; a rejected one falls through to the ordinary stage
  /// question, so a wrong guess costs a turn, never a bad booking.
  Future<bool> _assistCurrentStage(ParsedMessage p, AppState state) async {
    final client = _aiClient;
    if (client == null) return false;

    if (_assistStage != stage) {
      _assistStage = stage;
      _assistsForStage = 0;
    }
    if (_assistsForStage >= maxAssistsPerStage) return false;
    _assistsForStage++;

    final reply = await _askAi(client, _aiRequestFor(p, state));
    _rememberSummary(reply);

    // Whatever happens next, the model's own sentence is shown at most once,
    // up front -- every branch below either acts on the reply or falls back
    // to a plain question, and none of them needs to say it again.
    if (reply.hasText) {
      messages.add(AssistantMessage.assistant(reply.text!, assisted: true));
    }

    final fill = reply.slotFill;
    if (fill != null && await _applySlotFill(fill, state)) {
      clearActivePicker();
      await _advanceDraft(state);
      return true;
    }

    final proposal = reply.proposal;
    if (proposal != null && await _renderProposal(proposal, state)) {
      return true;
    }

    // No usable slot or proposal, but a sensible question: ask it, and keep
    // the picker open so tapping is still available.
    if (reply.hasText) {
      await _advanceDraft(state);
      return true;
    }

    aiDegraded = reply.degraded && reply.failureCode != 'disabled';
    return false;
  }

  /// Keep a summary the server produced, so the next turn can send it back.
  ///
  /// Only ever replaced by a newer one, never cleared by a turn that did not
  /// produce one: the model is asked for a summary only past a turn threshold,
  /// so most replies carry none and dropping the stored one on each of those
  /// would throw away the context on the very next message.
  void _rememberSummary(AssistantAiReply reply) {
    final summary = reply.summary;
    if (summary != null && summary.trim().isNotEmpty) {
      _contextSummary = summary.trim();
    }
  }

  /// Test seam over [_applySlotFill]. Exposed so the slot validators can be
  /// exercised directly, without scripting a whole model turn to reach them.
  @visibleForTesting
  Future<bool> debugApplySlotFill(
    Map<String, dynamic> fill,
    AppState state,
  ) => _applySlotFill(fill, state);

  /// Apply a model-proposed slot value through the same validators a typed or
  /// tapped value goes through. Returns false if anything about it is wrong.
  Future<bool> _applySlotFill(
    Map<String, dynamic> fill,
    AppState state,
  ) async {
    switch (fill['slot']) {
      case 'facility':
        final facility = state.bookableFacilities
            .where((item) => item.id == '${fill['facility_id']}')
            .firstOrNull;
        if (facility == null) return false;
        await selectFacility(facility, state);
        return true;
      case 'date':
        final day = DateTime.tryParse('${fill['day']}');
        if (day == null) return false;
        return _selectDateCore(day, state, appendUserMessage: false);
      case 'time':
        final start = (fill['start_hour'] as num?)?.toDouble();
        final end = (fill['end_hour'] as num?)?.toDouble();
        if (start == null || end == null || end <= start) return false;
        return _selectTimeCore(start, end, state, appendUserMessage: false);
      case 'heads':
        final raw = fill['heads'];
        // Truncating 12.5 to 12 would silently invent a headcount the user
        // never gave. A non-integer is refused outright, exactly as the typed
        // path refuses "12.5".
        if (raw is! num || raw != raw.roundToDouble()) return false;
        // _acceptHeadcount enforces capacity and whole-number rules and says
        // why when it refuses -- the model does not get to override it.
        return _acceptHeadcount(raw.toInt(), state) ==
            _StageInputResult.accepted;
      case 'purpose':
        final purpose = '${fill['purpose'] ?? ''}'.trim();
        if (purpose.length < 3) return false;
        draft.purpose = purpose;
        return true;
      default:
        return false;
    }
  }

  /// Whether [_applyStageScopedFallback] would get something out of this
  /// message, asked without any of its side effects.
  ///
  /// This is what keeps the free path free: the fallback already reads a bare
  /// "30", a facility name, or any few words of purpose, and a model call for
  /// those would be pure waste. Escalation is reserved for a stage that
  /// genuinely has nothing to work with.
  bool _deterministicCanFillStage(ParsedMessage p, AppState state) {
    switch (stage) {
      case AssistantStage.needFacility:
        if (draft.candidates.isNotEmpty && p.ordinal != null) {
          final index = p.ordinal! - 1;
          if (index >= 0 && index < draft.candidates.length) return true;
        }
        return resolveFacilityByName(p.raw, state.bookableFacilities).isNotEmpty;
      case AssistantStage.needHeads:
        // Any parse at all, valid or not: an out-of-range number still gets
        // the existing refusal, which is a better answer than a model guess.
        return _parseHeadcountText(p.raw).value != null;
      case AssistantStage.needPurpose:
        // A purpose is free text, so whatever the user typed is the purpose.
        return p.raw.trim().length >= 3;
      case AssistantStage.needDate:
      case AssistantStage.needTime:
      case AssistantStage.confirming:
      case AssistantStage.idle:
      case AssistantStage.submitting:
        return false;
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
          : normalizeRequestedAmenityLabels(
              draft.facility!,
              p.amenities,
            ).toSet();
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

    var queryMissed = false;
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
          _showFacilities(tied);
        }
        return tied.length == 1
            ? _StageInputResult.accepted
            : _StageInputResult.needsSelection;
      }
      // A query that named nothing is a fact worth keeping: without it the
      // unfiltered fallback below gets captioned as though it matched.
      queryMissed = true;
    }

    final amenities = p.amenities;
    final minCapacity = p.capacity?.min ?? draft.heads ?? 0;
    final category = p.category ?? 'All categories';
    var results = state.searchFacilities(
      minCapacity: minCapacity,
      amenities: amenities,
      category: category,
    );

    final scopedToActivity = _facilitiesForActivity(p.activity, state);
    if (scopedToActivity != null && category == 'All categories') {
      // A stated headcount still has to be honoured -- fall back to the
      // unfiltered activity list only when nothing meets both.
      final withCapacity = scopedToActivity
          .where((f) => f.capacity >= minCapacity)
          .toList();
      results = withCapacity.isNotEmpty ? withCapacity : scopedToActivity;
    }

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
        _showFacilities(top);
        return _StageInputResult.needsSelection;
      }
      results = biggest.take(3).toList();
    }

    final matched = !queryMissed && p.activity == null;
    if (results.length == 1) {
      draft.facility = results.first;
      _showFacilities(
        results,
        caption: matched ? 'Best match:' : 'Closest option:',
      );
    } else if (results.length > 1) {
      draft.candidates = results;
      _say(_unmatchedCaption(p, matched: matched));
      _showFacilities(results);
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
      _showFacilities(bigger.take(3).toList(), caption: 'Bigger options:');
    }
  }

  /// Bookable facilities that could host [activity], or null when the
  /// activity is unknown or nothing in the catalogue fits it.
  List<Facility>? _facilitiesForActivity(String? activity, AppState state) {
    if (activity == null) return null;
    final wanted = activityCategories[activity];
    if (wanted == null) return null;
    final scoped = state.bookableFacilities
        .where((f) => wanted.contains(f.category))
        .toList();
    return scoped.isEmpty ? null : scoped;
  }

  /// What to say above a list of facilities.
  ///
  /// "A few rooms fit" is a claim, and it may only be made when something
  /// actually matched. When the request named an activity or a facility we do
  /// not have, the list is a set of alternatives and has to read as one.
  ///
  /// The activity is preferred over the raw query on purpose: the leftover
  /// query for a garbled message can be junk like "iwant reservatio", and
  /// echoing that back is worse than saying nothing.
  String _unmatchedCaption(ParsedMessage p, {required bool matched}) {
    if (matched) return 'A few rooms fit — which one?';
    final activity = p.activity;
    if (activity != null) {
      return 'No facility here is set up for $activity. '
          'These are the closest you can book:';
    }
    return "I couldn't match that to a facility. Here's what you can book:";
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
            _showFacilities(tied);
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
            : 'Review and accept the Terms & Conditions for ${facility.name} before sending. Tap the button below — everything you told me is carried over, so only the terms are left.',
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
    var results = state.searchFacilities(
      minCapacity: p.capacity?.min ?? 0,
      amenities: p.amenities,
      category: p.category ?? 'All categories',
    );
    final scopedToActivity = _facilitiesForActivity(p.activity, state);
    if (scopedToActivity != null && p.category == null) {
      final minCapacity = p.capacity?.min ?? 0;
      final withCapacity = scopedToActivity
          .where((f) => f.capacity >= minCapacity)
          .toList();
      results = withCapacity.isNotEmpty ? withCapacity : scopedToActivity;
    }
    if (results.isEmpty) {
      _say('Nothing bookable matches that right now.');
      return;
    }
    // "N facilities match" is a claim, and it only holds when the message
    // actually constrained something. With no category, capacity, amenity or
    // facility name in it -- a request for an activity the parser could not
    // read, say -- `results` is the whole catalogue, and calling that a match
    // is how an Audio Visual Room got recommended for a pickleball game.
    final constrained =
        p.category != null ||
        p.capacity != null ||
        p.amenities.isNotEmpty ||
        (p.facilityQuery != null && p.facilityQuery!.isNotEmpty);
    if (p.activity != null || !constrained) {
      // The catalogue has nothing for the activity itself; these are the
      // rooms that could host it, which is a different claim.
      _say(_unmatchedCaption(p, matched: false));
    } else {
      _say(
        results.length == 1
            ? 'One match:'
            : '${results.length} facilities match:',
      );
    }
    _showFacilities(results.take(8).toList());
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
        _say(
          p.activity != null
              ? 'We don\'t have anything set up for ${p.activity}.'
              : 'I couldn\'t find a bookable room called "${p.facilityQuery}".',
        );
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
      _showFacilities(candidates.take(8).toList());
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
    _showReservations(mine);
  }

  void _handleCancelRequest(ParsedMessage p, AppState state) {
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

    // "Cancel this specific booking", "cancel the second one", "cancel my gym
    // booking" all narrow to one record here, in Dart. When they don't narrow
    // to exactly one, the assistant asks -- it never picks for the user.
    final scoped = _scopeReservations(p, cancellable, state);
    if (scoped.length == 1) {
      final target = scoped.first;
      frame.noteReservationFocus(target.id);
      _say(
        'Cancel ${target.facility} on ${target.whenLabel}? '
        'Tap Cancel on the card to confirm.',
        tone: AdvisoryTone.warn,
      );
      _showReservations([target]);
      return;
    }

    _say(
      scoped.isEmpty
          ? 'I could not tell which one you meant. Tap Cancel on the one you want to drop:'
          : 'Which one? Tap Cancel on the one you want to drop:',
    );
    _showReservations(scoped.isEmpty ? cancellable : scoped);
  }

  // ---------------------------------------------------------------------------
  // Informational intents.
  //
  // Each of these answers from records the app has already loaded, so they cost
  // nothing: no model call, and no extra round trip. Every number and date is
  // read straight off the server-computed reservation row -- nothing here
  // recalculates money or deadlines.
  // ---------------------------------------------------------------------------

  void _handleRecommendFacility(ParsedMessage p, AppState state) {
    final criteria = RecommendationCriteria(
      minCapacity: p.capacity?.max ?? p.capacity?.min,
      category: p.category,
      amenities: p.amenities,
      query: p.facilityQuery,
    );

    final ranked = rankFacilities(
      pool: state.bookableFacilities,
      criteria: criteria,
    );

    if (ranked.isEmpty) {
      final minCapacity = criteria.minCapacity;
      // Retry without the free-text query, scoped to whatever could host the
      // activity: "nothing matches" with no alternatives is a dead end, and
      // the query is exactly the constraint we know failed.
      final alternatives = _facilitiesForActivity(p.activity, state);
      if (alternatives != null) {
        _say(_unmatchedCaption(p, matched: false));
        _showFacilities(alternatives.take(5).toList());
        return;
      }
      if (minCapacity != null) {
        _suggestBiggerFacilities(minCapacity, state);
      } else {
        _say('Nothing bookable matches that right now.');
      }
      return;
    }

    final best = ranked.first;
    final lead = ranked.length == 1
        ? 'One fits: ${best.facility.name}'
        : '${best.facility.name} looks like the best fit';
    final why = best.reasonLine.isEmpty ? '' : ' — ${best.reasonLine}';
    _say('$lead$why.');

    if (best.isPartialMatch) {
      _say(
        'Heads up: it has no ${_joinLabels(best.missingAmenities)}.',
        tone: AdvisoryTone.warn,
      );
    }

    _showFacilities([for (final item in ranked) item.facility]);

    if (p.unknownAmenityWords.isNotEmpty) {
      _say(
        "I don't track ${_joinLabels(p.unknownAmenityWords.toList())} as an "
        'amenity, so I ignored it.',
      );
    }
  }

  void _handleReservationStatus(ParsedMessage p, AppState state) {
    final target = _singleReservationFor(p, state, action: 'check');
    if (target == null) return;

    final when = '${target.facility} on ${target.whenLabel}';
    _say('$when — ${target.lifecycleStatus.label}.');

    final next = _nextStepFor(target, state);
    if (next != null) _say(next);
    _showReservations([target]);
  }

  void _handlePayment(ParsedMessage p, AppState state) {
    final target = _singleReservationFor(p, state, action: 'check');
    if (target == null) return;

    frame.noteReservationFocus(target.id);

    if (target.totalAmountCentavos == 0) {
      _say(
        target.isPaymentExempt
            ? '${target.facility} on ${target.whenLabel} has no charge — '
                  'your account type is exempt.'
            : '${target.facility} on ${target.whenLabel} has nothing to pay.',
      );
      return;
    }

    final outstanding = target.outstandingAmountCentavos;
    if (outstanding == 0) {
      _say(
        '${target.facility} on ${target.whenLabel} is fully paid — '
        '${pesoFromCentavos(target.totalAmountCentavos)} verified.',
      );
      return;
    }

    // Both the amount and the deadline land in one answer, so "how much do I
    // owe and when is it due" needs a single turn rather than two.
    final parts = <String>[
      'You still owe ${pesoFromCentavos(outstanding)} on ${target.facility} '
          '(${target.whenLabel}).',
    ];
    final deadline = _paymentDeadlineLine(target);
    if (deadline != null) parts.add(deadline);
    _say(parts.join(' '), tone: _paymentTone(target));

    if (target.aggregatePaymentStatus == AggregatePaymentStatus.unpaid &&
        target.requiredDownPaymentCentavos > 0 &&
        target.requiredDownPaymentCentavos < target.totalAmountCentavos) {
      _say(
        'A ${target.downPaymentPercent}% down payment of '
        '${pesoFromCentavos(target.requiredDownPaymentCentavos)} holds the '
        'booking; the rest follows before your schedule.',
      );
    }
    _showReservations([target]);
  }

  Future<void> _handlePermitStatus(ParsedMessage p, AppState state) async {
    final target = _singleReservationFor(p, state, action: 'check');
    if (target == null) return;

    frame.noteReservationFocus(target.id);
    final permit = target.permit;

    // The storage layer, not the client, decides whether a requester may pull
    // the PDF: a permit can be fully generated and still undelivered.
    if (permit != null && permit.isDownloadable) {
      _say(
        'Yes — your permit for ${target.facility} (${target.whenLabel}) is '
        'ready. Open the reservation to download it.',
      );
      _showReservations([target]);
      return;
    }

    final readiness = await state.permitReadiness(target.id);
    if (readiness == null) {
      _say(
        permit == null
            ? 'Your permit for ${target.facility} has not been issued yet. '
                  'It follows approval and payment.'
            : "Your permit is being prepared and isn't downloadable yet.",
      );
      _showReservations([target]);
      return;
    }

    if (readiness.ready && permit != null && permit.isGenerated) {
      _say(
        'The permit is generated but has not been released to you yet — an '
        'administrator still has to send it.',
      );
      _showReservations([target]);
      return;
    }

    final blockers = readiness.blockerCodes;
    if (blockers.isEmpty) {
      _say(
        "Nothing is blocking it — the permit just hasn't been generated yet.",
      );
      _showReservations([target]);
      return;
    }

    _say(
      blockers.length == 1
          ? "Not yet — ${_lowerFirst(readiness.messageFor(blockers.first))}"
          : 'Not yet. ${blockers.length} things are still outstanding:',
      tone: AdvisoryTone.warn,
    );
    if (blockers.length > 1) {
      for (final code in blockers.take(4)) {
        _say('• ${readiness.messageFor(code)}');
      }
    }
    _showReservations([target]);
  }

  void _handlePermitRequirements() {
    _say(
      'A permit is released once the reservation is approved, the required '
      'payment is verified, the official form items are mapped, and every '
      'signature slot is filled.',
    );
    _say(
      'Internal permits need your Office/College; external ones also need your '
      'company, address, contact numbers and admission fee.',
    );
  }

  void _handleEquipment(ParsedMessage p, AppState state) {
    final pool = state.bookableFacilities;
    Facility? facility;

    if (p.facilityQuery != null && p.facilityQuery!.isNotEmpty) {
      final matches = _tiedTop(resolveFacilityByName(p.facilityQuery!, pool));
      if (matches.length == 1) facility = matches.first;
    }
    facility ??= draft.facility;
    if (facility == null && frame.focusFacilityId != null) {
      facility = pool
          .where((item) => item.id == frame.focusFacilityId)
          .firstOrNull;
    }

    if (facility == null) {
      _say('Which facility? Equipment is listed per room.');
      _showFacilities(pool.take(8).toList());
      return;
    }

    frame.noteFacilityFocus(facility.id);
    final catalogue = facility.amenities;
    final priced = [
      for (final option in facility.amenityOptions)
        if (option.enabled) option,
    ];

    if (catalogue.isEmpty && priced.isEmpty) {
      _say('${facility.name} has no equipment listed.');
      return;
    }

    if (catalogue.isNotEmpty) {
      _say('${facility.name} includes ${_joinLabels(catalogue)}.');
    }
    if (priced.isNotEmpty) {
      _say(
        'Bookable add-ons: '
        '${priced.map((item) => '${item.name} '
            '(${pesoFromCentavos(item.priceCentavos)})').join(', ')}.',
      );
    }
    _say(
      'Availability follows the reservation itself — request them when you '
      'book and an administrator confirms them.',
    );
  }

  void _handleAnnouncements(AppState state) {
    final unread = [
      for (final item in state.notifications)
        if (item.unread) item,
    ];
    final recent = unread.isNotEmpty ? unread : state.notifications;

    if (recent.isEmpty) {
      _say('Nothing new for you right now.');
      return;
    }

    _say(
      unread.isNotEmpty
          ? 'You have ${_formatCount(unread.length)} unread '
                '${unread.length == 1 ? 'notice' : 'notices'}:'
          : 'Your most recent notices:',
    );
    for (final item in recent.take(5)) {
      _say('• ${item.title}${item.body.isEmpty ? '' : ' — ${item.body}'}');
    }

    final maintenance = [
      for (final facility in state.facilities)
        if (facility.state == FacilityState.maintenance) facility.name,
    ];
    if (maintenance.isNotEmpty) {
      _say(
        'Also under maintenance: ${_joinLabels(maintenance.take(3).toList())}.',
        tone: AdvisoryTone.warn,
      );
    }
  }

  Future<void> _handlePolicyFaq(ParsedMessage p, AppState state) async {
    // The knowledge base is the authority: its wording is the app's own, and
    // the database has already filtered it to what this account's lane may
    // see. Only when it is unreachable -- offline, demo mode, or a failed
    // lookup -- does the built-in prose below answer instead.
    final chunks = await state.assistantKnowledge(p.raw, limit: 2);
    if (chunks.isNotEmpty) {
      for (final chunk in chunks) {
        _say(chunk.answer);
      }
      return;
    }
    _sayBuiltInPolicy(p, state);
  }

  void _sayBuiltInPolicy(ParsedMessage p, AppState state) {
    final normalized = p.normalized;
    final account = state.userAccount;

    if (RegExp(r'\bexternal|guest|renter|outside\b').hasMatch(normalized)) {
      _say(
        'External renters pay the guest rate for the facility plus any add-ons, '
        'settle a down payment to hold the booking, and clear the balance '
        'before the schedule.',
      );
      _say(
        'An external permit also needs your company or organization, complete '
        'address, contact numbers and admission fee before it can be released.',
      );
      return;
    }

    if (RegExp(r'\bcancel').hasMatch(normalized)) {
      _say(
        'You can cancel any reservation that has not started yet, and there is '
        'no cancellation fee. Once a schedule has begun it can no longer be '
        'cancelled from here.',
      );
      return;
    }

    if (RegExp(r'\bpay|payment|down ?payment\b').hasMatch(normalized)) {
      _say(
        'Verified students and faculty reserve at no charge. Everyone else '
        'pays a down payment to hold the booking, then the balance before the '
        'schedule starts.',
      );
      return;
    }

    _say(
      'To reserve: pick a facility that accepts your account type, choose a '
      'date and time inside its opening hours, give the headcount and purpose, '
      'and accept the reservation terms. An administrator then approves it.',
    );
    _say(
      'Your account reserves as ${account.pricingAudience}, '
      '${account.isPaymentExempt ? 'which is exempt from facility charges.' : 'so facility charges apply.'}',
    );
  }

  // ---------------------------------------------------------------------------
  // Shared helpers for the informational handlers.
  // ---------------------------------------------------------------------------

  /// Narrow the user's reservations to the ones this message could mean.
  ///
  /// Honours an ordinal against what was last shown, an explicit facility name,
  /// and the current focus -- in that order of specificity. Returns everything
  /// when the message names nothing, so callers can decide whether to ask.
  List<ReservationRequest> _scopeReservations(
    ParsedMessage p,
    List<ReservationRequest> pool,
    AppState state,
  ) {
    if (pool.isEmpty) return const [];

    if (p.ordinal != null) {
      final resolution = frame.resolveReservation(
        ordinal: p.ordinal,
        available: [for (final r in pool) r.id],
      );
      if (resolution.isResolved) {
        return [
          for (final r in pool)
            if (r.id == resolution.id) r,
        ];
      }
      if (resolution.outcome == ReferenceOutcome.outOfRange) return const [];
    }

    final byFacility = _scopeByFacilityName(p, pool, state);
    if (byFacility != null) return byFacility;

    if (pool.length == 1) return pool;

    final focus = frame.focusReservationId;
    if (focus != null) {
      final matched = [
        for (final r in pool)
          if (r.id == focus) r,
      ];
      if (matched.isNotEmpty) return matched;
    }

    return pool;
  }

  /// "my reservation in basketball court" -> the reservations at that facility.
  /// Returns null when the message named no facility at all, so the caller can
  /// tell "named nothing" apart from "named something with no matches".
  List<ReservationRequest>? _scopeByFacilityName(
    ParsedMessage p,
    List<ReservationRequest> pool,
    AppState state,
  ) {
    final query = p.facilityQuery;
    final category = p.category;
    if ((query == null || query.isEmpty) && category == null) return null;

    final candidates = <Facility>[];
    if (query != null && query.isNotEmpty) {
      candidates.addAll(
        _tiedTop(resolveFacilityByName(query, state.facilities)),
      );
    }
    if (candidates.isEmpty && category != null) {
      candidates.addAll(
        state.facilities.where((facility) => facility.category == category),
      );
    }
    if (candidates.isEmpty) {
      // Fall back to the reservation's own denormalized facility name, which
      // survives even when the facility row is no longer browsable.
      final needle = (query ?? category ?? '').toLowerCase();
      final byName = [
        for (final r in pool)
          if (needle.isNotEmpty && r.facility.toLowerCase().contains(needle)) r,
      ];
      if (byName.isNotEmpty) return byName;

      // Nothing recognised the token, so the user named no facility at all --
      // it is leftover wording like "pay" in "how much do I need to pay".
      // Reporting "no match" here would wrongly discard every candidate.
      return null;
    }

    final ids = {for (final facility in candidates) facility.id};
    final names = {
      for (final facility in candidates) facility.name.toLowerCase(),
    };
    return [
      for (final r in pool)
        if (ids.contains(r.facilityId) || names.contains(r.facility.toLowerCase()))
          r,
    ];
  }

  /// Resolve to exactly one reservation, or say why not and return null.
  ReservationRequest? _singleReservationFor(
    ParsedMessage p,
    AppState state, {
    required String action,
  }) {
    final mine = state.myRequests;
    if (mine.isEmpty) {
      _say('Nothing booked yet, so there is nothing to $action.');
      return null;
    }

    final scoped = _scopeReservations(p, mine, state);
    if (scoped.length == 1) {
      frame.noteReservationFocus(scoped.first.id);
      return scoped.first;
    }

    if (scoped.isEmpty) {
      _say("I couldn't match that to any of your reservations. Here they are:");
      _showReservations(mine);
      return null;
    }

    _say('Which one do you mean?');
    _showReservations(scoped);
    return null;
  }

  String? _paymentDeadlineLine(ReservationRequest request) {
    final now = campusNow();
    final balanceDue = request.balanceDueAt;
    final paymentDue = request.paymentDueAt;
    final verified = request.verifiedAmountCentavos;

    // Before the down payment lands, the deposit window is the live deadline;
    // after it, the balance date is.
    final due = verified < request.requiredDownPaymentCentavos
        ? (paymentDue ?? balanceDue)
        : (balanceDue ?? paymentDue);
    if (due == null) return null;

    final local = campusWallTime(due.toUtc());
    if (local.isBefore(now)) {
      return 'That was due ${formatStamp(local)} and is now overdue.';
    }
    return 'Due ${formatStamp(local)}.';
  }

  AdvisoryTone? _paymentTone(ReservationRequest request) =>
      switch (request.aggregatePaymentStatus) {
        AggregatePaymentStatus.overdue => AdvisoryTone.block,
        AggregatePaymentStatus.needsCorrection => AdvisoryTone.warn,
        _ => null,
      };

  /// One short sentence about what happens next, or null when the status
  /// already says everything.
  String? _nextStepFor(ReservationRequest request, AppState state) {
    switch (request.lifecycleStatus) {
      case ReservationLifecycleStatus.pendingApproval:
        return 'An administrator still has to review it.';
      case ReservationLifecycleStatus.changesRequested:
        // The administrator's wording lives on the reservation's event trail,
        // not on the row, so the card is where the reason is read.
        return 'Changes were requested — open it to read why and resubmit.';
      case ReservationLifecycleStatus.awaitingPayment:
        final outstanding = request.outstandingAmountCentavos;
        if (outstanding == 0) return 'Your payment is being verified.';
        final deadline = _paymentDeadlineLine(request);
        return 'Pay ${pesoFromCentavos(outstanding)} to confirm it.'
            '${deadline == null ? '' : ' $deadline'}';
      case ReservationLifecycleStatus.confirmed:
        final permit = request.permit;
        if (permit != null && permit.isDownloadable) {
          return 'Your permit is ready to download.';
        }
        if (request.signatureRequested) {
          return 'Your e-signature is still needed for the permit.';
        }
        return null;
      case ReservationLifecycleStatus.declined:
        return 'Open it to read the administrator\'s reason.';
      case ReservationLifecycleStatus.cancelled:
      case ReservationLifecycleStatus.expired:
      case ReservationLifecycleStatus.completed:
        return null;
    }
  }

  /// Render a reservation list and record it as what ordinals now refer to.
  void _showReservations(List<ReservationRequest> items) {
    messages.add(AssistantMessage.reservationList('', items));
    frame.noteReservations([for (final item in items) item.id]);
  }

  /// Render a facility list and record it as what ordinals now refer to.
  ///
  /// Every facility list must come through here. Several paths used to add the
  /// message directly, including the two commonest -- browsing facilities and
  /// checking a day -- which left the reference frame empty precisely when the
  /// user was most likely to say "book the second one". The follow-up then had
  /// nothing to resolve against and the assistant asked which room, having
  /// just listed them.
  void _showFacilities(List<Facility> items, {String caption = ''}) {
    messages.add(AssistantMessage.facilityList(caption, items));
    frame.noteFacilities([for (final item in items) item.id]);
  }

  String _joinLabels(List<String> values) {
    if (values.isEmpty) return '';
    if (values.length == 1) return values.first;
    if (values.length == 2) return '${values.first} and ${values.last}';
    return '${values.take(values.length - 1).join(', ')} and ${values.last}';
  }

  String _lowerFirst(String value) =>
      value.isEmpty ? value : value[0].toLowerCase() + value.substring(1);
}
