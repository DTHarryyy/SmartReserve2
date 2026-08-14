import 'package:flutter/material.dart';

/// A single humanised line in an audit entry's expanded detail.
///
/// Either a before/after pair (`before`/`after` set, `note` null) or a
/// standalone note (`note` set, `before`/`after` null) — e.g. a summary line
/// for a creation event, or a fallback when no field-level change survived
/// humanisation.
@immutable
class AuditChange {
  const AuditChange({required this.label, this.before, this.after, this.note})
    : assert(
        note == null || (before == null && after == null),
        'A change is either a before/after pair or a note, not both.',
      );

  const AuditChange.note(String text) : this(label: '', note: text);

  final String label;
  final String? before;
  final String? after;
  final String? note;

  bool get isNote => note != null;
}
