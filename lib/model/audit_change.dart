import 'package:flutter/material.dart';

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
