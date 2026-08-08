import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

enum AuditKind {
  facility('facility', 'FACILITY', SR.blueTint, SR.blueDark),
  reservation('reservation', 'RESERVATION', SR.greenTint, SR.greenDark),
  account('account', 'ACCOUNT', SR.dividerSoft, SR.ink4);

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
    String two(int v) => v.toString().padLeft(2, '0');
    const months = [
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
    return AuditEntry(
      id: 'a-${at.microsecondsSinceEpoch}',
      actor: actor,
      actorRole: actorRole,
      action: action,
      target: target,
      kind: kind,
      when: 'Just now',
      absolute:
          '${at.day} ${months[at.month - 1]} ${at.year}, '
          '${two(at.hour)}:${two(at.minute)}',
      material: material,
      diff: diff,
      reason: reason,
      revertable: revertable,
      recordId: recordId,
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

  String get initials => actor
      .replaceAll(RegExp(r'[^A-Za-z. ]'), ' ')
      .split(RegExp(r'[\s.]+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0].toUpperCase())
      .join();

  String toCsvRow() {
    String cell(String v) => '"${v.replaceAll('"', '""')}"';
    return [
      cell(absolute),
      cell(actor),
      cell(actorRole),
      cell('$action $target'),
      cell(kind.label),
      cell(material ? 'material' : 'routine'),
      cell(diff.join(' | ')),
      cell(reason),
    ].join(',');
  }

  static const csvHeader =
      'timestamp,actor,role,action,record_type,significance,change,reason';
}
