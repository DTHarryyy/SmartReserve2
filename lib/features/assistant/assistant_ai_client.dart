/// The client half of the cloud-model escalation.
///
/// Every failure mode here resolves to the same thing: a reply of null, which
/// the controller reads as "answer this the deterministic way". The assistant
/// existed and worked before this layer, so nothing it does may be allowed to
/// break a conversation -- an outage should be invisible apart from a slightly
/// blunter answer.
library;

import 'dart:async';

import '../../backend/supabase_service.dart';
import 'assistant_reference_frame.dart';

/// A model-assisted answer, or the absence of one.
class AssistantAiReply {
  const AssistantAiReply({
    this.text,
    this.toolsUsed = const [],
    this.slotFill,
    this.proposal,
    this.facilityIds = const [],
    this.summary,
    this.degraded = false,
    this.failureCode,
    this.retryAfterSeconds,
  });

  /// Null whenever the caller should fall back to the rule-based answer.
  final String? text;
  final List<String> toolsUsed;

  /// A booking slot value the model proposed. Still has to pass the same
  /// validators a typed or tapped value would.
  final Map<String, dynamic>? slotFill;

  /// A booking or cancellation the model proposed. Never executed here.
  final Map<String, dynamic>? proposal;

  /// Facility ids this turn's tool calls surfaced (from recommend_facilities
  /// or get_available_facilities), so the caller can render them as real,
  /// tappable cards instead of the model enumerating them in prose.
  final List<String> facilityIds;

  /// A rolling precis of the conversation so far, produced by the model on
  /// the same call that answered. Sent back on the next turn so history can
  /// stay capped without the earlier turns being simply forgotten.
  final String? summary;

  /// True when the service answered but said it could not help this time.
  final bool degraded;
  final String? failureCode;
  final int? retryAfterSeconds;

  bool get hasText => text != null && text!.trim().isNotEmpty;

  static const unavailable = AssistantAiReply(
    degraded: true,
    failureCode: 'unavailable',
  );
}

/// What the client sends up. Ids and short text only -- never records.
class AssistantAiRequest {
  const AssistantAiRequest({
    required this.message,
    this.conversationId,
    this.history = const [],
    this.summary,
    this.frame,
    this.inBookingFlow = false,
    this.bookingDraft,
    this.turnCount = 0,
  });

  final String message;
  final String? conversationId;

  /// Recent turns, oldest first. The server trims this again; sending fewer
  /// here simply costs less.
  final List<({String role, String content})> history;
  final String? summary;

  /// Total turns in this conversation, not just the ones being replayed. The
  /// server asks for a summary only once this outgrows the history window.
  final int turnCount;
  final AssistantReferenceFrame? frame;
  final bool inBookingFlow;
  final Map<String, dynamic>? bookingDraft;

  Map<String, dynamic> toJson() => {
    'message': message,
    if (conversationId != null) 'conversationId': conversationId,
    if (history.isNotEmpty)
      'history': [
        for (final turn in history) {'role': turn.role, 'content': turn.content},
      ],
    if (summary != null && summary!.trim().isNotEmpty) 'summary': summary,
    if (turnCount > 0) 'turn_count': turnCount,
    if (frame != null && !frame!.isEmpty) 'context': frame!.toContextPayload(),
    if (inBookingFlow) 'in_booking_flow': true,
    if (bookingDraft != null) 'booking_draft': bookingDraft,
  };
}

/// Calls the `assistant-chat` Edge Function.
///
/// Kept as an interface so tests can substitute a failing or silent
/// implementation and assert that the assistant still answers.
abstract interface class AssistantAiClient {
  Future<AssistantAiReply> ask(AssistantAiRequest request);
}

class SupabaseAssistantAiClient implements AssistantAiClient {
  const SupabaseAssistantAiClient(this._backend);

  final SmartReserveBackend _backend;

  @override
  Future<AssistantAiReply> ask(AssistantAiRequest request) async {
    try {
      final data = await _backend.assistantChat(request.toJson());
      return parseAssistantAiReply(data);
    } catch (_) {
      // Deliberately swallowed. The caller has a correct answer available
      // without us, and a raw backend message must never reach a user.
      return AssistantAiReply.unavailable;
    }
  }
}

/// Parse a response body. Pure, so the mapping is testable without a network.
AssistantAiReply parseAssistantAiReply(Map<String, dynamic> data) {
  // The kill switch is a normal outcome, not a failure: it means "the
  // deterministic answer is the answer".
  if (data['disabled'] == true) {
    return const AssistantAiReply(degraded: true, failureCode: 'disabled');
  }
  if (data['fallback'] == true) {
    return AssistantAiReply(
      degraded: true,
      failureCode: '${data['code'] ?? 'fallback'}',
    );
  }

  final code = data['code'];
  if (code is String && code.isNotEmpty) {
    final retry = data['retry_after_seconds'];
    return AssistantAiReply(
      degraded: true,
      failureCode: code,
      retryAfterSeconds: retry is num ? retry.toInt() : null,
    );
  }

  final reply = data['reply'];
  if (reply is! String || reply.trim().isEmpty) {
    return const AssistantAiReply(degraded: true, failureCode: 'empty_reply');
  }

  return AssistantAiReply(
    text: reply.trim(),
    toolsUsed: [
      for (final tool in data['tools_used'] as List? ?? const []) '$tool',
    ],
    slotFill: data['slot_fill'] is Map
        ? Map<String, dynamic>.from(data['slot_fill'] as Map)
        : null,
    proposal: data['proposal'] is Map
        ? Map<String, dynamic>.from(data['proposal'] as Map)
        : null,
    facilityIds: [
      for (final id in data['facility_ids'] as List? ?? const []) '$id',
    ],
    summary: data['summary'] is String && (data['summary'] as String).trim().isNotEmpty
        ? (data['summary'] as String).trim()
        : null,
  );
}
