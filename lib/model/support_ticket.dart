import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

/// Validation limits, mirrored exactly by the CHECK constraints in
/// 20261025120000_support_tickets.sql.
abstract final class SupportLimits {
  static const subjectMin = 3;
  static const subjectMax = 120;
  static const messageMin = 10;
  static const messageMax = 2000;
  static const replyMin = 3;
  static const replyMax = 1000;
  static const attachmentMaxBytes = 5 * 1024 * 1024;
}

enum SupportCategory {
  account('account', 'Account & sign-in', Icons.manage_accounts_outlined),
  reservation('reservation', 'Reservations', Icons.event_note_outlined),
  payment('payment', 'Payments & GCash', Icons.payments_outlined),
  bug('bug', 'Something is broken', Icons.bug_report_outlined),
  other('other', 'Something else', Icons.help_outline_rounded);

  const SupportCategory(this.raw, this.label, this.icon);

  final String raw;
  final String label;
  final IconData icon;

  static SupportCategory fromRaw(String? raw) =>
      values.firstWhere((value) => value.raw == raw, orElse: () => other);
}

enum SupportStatus {
  open('open', 'Open', SrTone.warning),
  inProgress('in_progress', 'In progress', SrTone.info),
  resolved('resolved', 'Resolved', SrTone.success),
  closed('closed', 'Closed', SrTone.neutral);

  const SupportStatus(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  bool get isActive => this == open || this == inProgress;

  static SupportStatus fromRaw(String? raw) =>
      values.firstWhere((value) => value.raw == raw, orElse: () => open);
}

class SupportReply {
  const SupportReply({
    required this.id,
    required this.authorName,
    required this.fromAdmin,
    required this.message,
    required this.createdAt,
    this.authorId,
  });

  final String id;
  final String? authorId;
  final String authorName;
  final bool fromAdmin;
  final String message;
  final DateTime createdAt;

  factory SupportReply.fromJson(Map<String, dynamic> json) => SupportReply(
    id: '${json['id']}',
    authorId: json['author_id'] as String?,
    authorName: '${json['author_name'] ?? ''}',
    fromAdmin: json['from_admin'] as bool? ?? false,
    message: '${json['message'] ?? ''}',
    createdAt: DateTime.parse('${json['created_at']}').toLocal(),
  );
}

class SupportTicket {
  const SupportTicket({
    required this.id,
    required this.requesterId,
    required this.requesterName,
    required this.requesterEmail,
    required this.category,
    required this.subject,
    required this.message,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
    this.attachmentPath,
    this.resolvedAt,
    this.replies = const [],
  });

  final String id;
  final String requesterId;
  final String requesterName;
  final String requesterEmail;
  final SupportCategory category;
  final String subject;
  final String message;
  final String? attachmentPath;
  final SupportStatus status;
  final DateTime createdAt;
  final DateTime lastActivityAt;
  final DateTime? resolvedAt;

  /// Oldest first.
  final List<SupportReply> replies;

  /// The last word was the requester's, so the queue owes them an answer.
  bool get awaitingAdmin =>
      status.isActive && (replies.isEmpty || !replies.last.fromAdmin);

  factory SupportTicket.fromJson(Map<String, dynamic> json) {
    final requester = json['requester'] is Map
        ? Map<String, dynamic>.from(json['requester'] as Map)
        : const <String, dynamic>{};
    final replies = [
      for (final raw in json['replies'] as List? ?? const [])
        SupportReply.fromJson(Map<String, dynamic>.from(raw as Map)),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final email = '${requester['email'] ?? ''}';
    final name = '${requester['full_name'] ?? ''}'.trim();
    return SupportTicket(
      id: '${json['id']}',
      requesterId: '${json['requester_id']}',
      requesterName: name.isEmpty ? email : name,
      requesterEmail: email,
      category: SupportCategory.fromRaw(json['category'] as String?),
      subject: '${json['subject'] ?? ''}',
      message: '${json['message'] ?? ''}',
      attachmentPath: json['attachment_path'] as String?,
      status: SupportStatus.fromRaw(json['status'] as String?),
      createdAt: DateTime.parse('${json['created_at']}').toLocal(),
      lastActivityAt: DateTime.parse(
        '${json['last_activity_at'] ?? json['created_at']}',
      ).toLocal(),
      resolvedAt: json['resolved_at'] == null
          ? null
          : DateTime.tryParse('${json['resolved_at']}')?.toLocal(),
      replies: replies,
    );
  }
}

/// A new ticket as typed into the form; validated before it is sent.
class SupportTicketDraft {
  const SupportTicketDraft({
    required this.category,
    required this.subject,
    required this.message,
  });

  final SupportCategory category;
  final String subject;
  final String message;

  /// Null when valid, otherwise the message to show.
  String? get error {
    final subjectLength = subject.trim().length;
    final messageLength = message.trim().length;
    if (subjectLength < SupportLimits.subjectMin ||
        subjectLength > SupportLimits.subjectMax) {
      return 'Give the ticket a subject of ${SupportLimits.subjectMin}–'
          '${SupportLimits.subjectMax} characters.';
    }
    if (messageLength < SupportLimits.messageMin ||
        messageLength > SupportLimits.messageMax) {
      return 'Describe the problem in ${SupportLimits.messageMin}–'
          '${SupportLimits.messageMax} characters.';
    }
    return null;
  }
}
