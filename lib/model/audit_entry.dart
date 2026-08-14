import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import '../util/campus_calendar.dart' show formatStamp;
import 'account.dart';
import 'audit_change.dart';
import 'audit_diff.dart';

enum AuditKind {
  facility('facility', 'FACILITY', SR.blueTint, SR.blueDark),
  reservation('reservation', 'RESERVATION', SR.greenTint, SR.greenDark),
  account('account', 'ACCOUNT', SR.dividerSoft, SR.ink4),
  system('system', 'SYSTEM', SR.hairline, SR.muted);

  const AuditKind(this.raw, this.label, this.background, this.foreground);

  final String raw;
  final String label;
  final Color background;
  final Color foreground;

  static AuditKind fromRaw(String raw) =>
      values.firstWhere((k) => k.raw == raw, orElse: () => AuditKind.facility);
}

@immutable
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.actor,
    required this.actorRole,
    required this.action,
    required this.target,
    required this.kind,
    required this.when,
    required this.absolute,
    required this.material,
    required this.diff,
    this.reason = '',
    this.revertable = false,
    this.recordId,
    this.createdAt,
    this.changes = const [],
    this.actorEmail = '',
    this.rawBefore = const {},
    this.rawAfter = const {},
    this.rawDetails = const {},
  });

  factory AuditEntry.now({
    required String actor,
    required String actorRole,
    required String action,
    required String target,
    required AuditKind kind,
    required List<String> diff,
    String reason = '',
    bool material = true,
    bool revertable = false,
    String? recordId,
  }) {
    final at = DateTime.now();
    return AuditEntry(
      id: 'a-${at.microsecondsSinceEpoch}',
      actor: actor,
      actorRole: actorRole,
      action: action,
      target: target,
      kind: kind,
      when: 'Just now',
      absolute: formatStamp(at),
      material: material,
      diff: diff,
      reason: reason,
      revertable: revertable,
      recordId: recordId,
      createdAt: at,
    );
  }

  final String id;
  final String actor;
  final String actorRole;

  final String action;
  final String target;
  final AuditKind kind;

  final String when;

  final String absolute;

  final bool material;

  final List<String> diff;
  final String reason;
  final bool revertable;

  final String? recordId;

  /// The pagination cursor. Populated for both demo and remote entries;
  /// `absolute` is for display only and must never be re-parsed for paging.
  final DateTime? createdAt;

  /// Humanised, structured changes — the preferred way to render an
  /// entry's detail. Falls back to [diff] when empty (demo entries keep
  /// their hand-written diff strings).
  final List<AuditChange> changes;

  final String actorEmail;

  /// Untrimmed payloads, kept for the "show technical details" disclosure.
  /// The audit trail must never lose information — only the default view
  /// hides noise.
  final Map<String, dynamic> rawBefore;
  final Map<String, dynamic> rawAfter;
  final Map<String, dynamic> rawDetails;

  /// The actor's role as a typed [AccountRole], when it maps to one.
  /// `system`-role entries and any future role slugs return null rather
  /// than throwing.
  AccountRole? get actorRoleValue {
    try {
      return AccountRole.fromRaw(actorRole);
    } on ArgumentError {
      return null;
    }
  }

  bool get isSystemActor => actorRole == 'system';

  factory AuditEntry.fromJson(Map<String, dynamic> json) {
    final createdAt =
        DateTime.tryParse('${json['created_at'] ?? ''}')?.toLocal() ??
        DateTime.now();
    final details = Map<String, dynamic>.from(
      (json['details'] as Map?) ?? const {},
    );
    final before = Map<String, dynamic>.from(
      (json['before_values'] as Map?) ?? const {},
    );
    final after = Map<String, dynamic>.from(
      (json['after_values'] as Map?) ?? const {},
    );
    final legacyDiff = <String>[
      ...details.entries.map((entry) => '${entry.key}: ${entry.value}'),
    ];
    for (final key in {...before.keys, ...after.keys}) {
      if (before[key] != after[key]) {
        legacyDiff.add('$key: ${before[key] ?? '—'} → ${after[key] ?? '—'}');
      }
    }
    final entityType = '${json['entity_type'] ?? 'facility'}';
    final action = '${json['action'] ?? ''}';
    return AuditEntry(
      id: '${json['id']}',
      actor: '${json['actor_name'] ?? 'System'}',
      actorRole: '${json['actor_role'] ?? 'system'}',
      action: action,
      target: '${json['target_label'] ?? ''}',
      kind: AuditKind.fromRaw(entityType),
      when: _relative(createdAt),
      absolute: formatStamp(createdAt),
      material: json['material'] as bool? ?? true,
      diff: legacyDiff,
      reason: '${json['reason'] ?? ''}',
      revertable: json['revertable'] as bool? ?? false,
      recordId: json['entity_id'] as String?,
      createdAt: createdAt,
      changes: humanizeAuditPayload(
        entityType: entityType,
        action: action,
        details: details,
        before: before,
        after: after,
      ),
      actorEmail: '${json['actor_email'] ?? ''}',
      rawBefore: before,
      rawAfter: after,
      rawDetails: details,
    );
  }

  static String _relative(DateTime value) {
    final delta = DateTime.now().difference(value);
    if (delta.inMinutes < 2) return 'Just now';
    if (delta.inHours < 1) return '${delta.inMinutes} min ago';
    if (delta.inDays < 1) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }

  String get initials => actor
      .replaceAll(RegExp(r'[^A-Za-z. ]'), ' ')
      .split(RegExp(r'[\s.]+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0].toUpperCase())
      .join();

  String toCsvRow() {
    String cell(String v) => '"${v.replaceAll('"', '""')}"';
    final changeText = changes.isNotEmpty
        ? changes.map(_csvChangeLine).join(' | ')
        : diff.join(' | ');
    return [
      cell(createdAt?.toUtc().toIso8601String() ?? absolute),
      cell(actor),
      cell(actorEmail),
      cell(actorRole),
      cell('$action $target'),
      cell(kind.label),
      cell(material ? 'material' : 'routine'),
      cell(changeText),
      cell(reason),
    ].join(',');
  }

  static String _csvChangeLine(AuditChange change) {
    if (change.isNote) return change.note!;
    if (change.before == null) return '${change.label}: ${change.after}';
    return '${change.label}: ${change.before} → ${change.after}';
  }

  static const csvHeader =
      'timestamp,actor,actor_email,role,action,record_type,significance,'
      'change,reason';
}
