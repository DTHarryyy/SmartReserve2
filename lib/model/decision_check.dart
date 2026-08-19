import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

enum CheckOutcome {
  pass(Icons.check_rounded, SrTone.success, SR.ink3),
  warn(Icons.priority_high_rounded, SrTone.warning, null),
  fail(Icons.close_rounded, SrTone.error, null),
  info(Icons.remove_rounded, SrTone.neutral, null);

  const CheckOutcome(this.mark, this.tone, this._valueColorOverride);

  final IconData mark;
  final SrTone tone;
  final Color? _valueColorOverride;

  Color get background => tone.tint;
  Color get foreground => tone.ink;
  Color get valueColor => _valueColorOverride ?? tone.ink;
}

@immutable
class DecisionCheck {
  const DecisionCheck({
    required this.label,
    required this.value,
    required this.outcome,
  });

  final String label;
  final String value;
  final CheckOutcome outcome;

  bool get blocking =>
      outcome != CheckOutcome.pass && outcome != CheckOutcome.info;
}

@immutable
class CheckSummary {
  const CheckSummary({
    required this.text,
    required this.background,
    required this.borderColor,
    required this.foreground,
  });

  factory CheckSummary.clear(String text) =>
      CheckSummary._of(text, SrTone.success);

  factory CheckSummary.caution(String text) =>
      CheckSummary._of(text, SrTone.warning);

  factory CheckSummary.blocked(String text) =>
      CheckSummary._of(text, SrTone.error);

  CheckSummary._of(String text, SrTone tone)
    : this(
        text: text,
        background: tone.tint,
        borderColor: tone.line,
        foreground: tone.ink,
      );

  final String text;
  final Color background;
  final Color borderColor;
  final Color foreground;

  static CheckSummary of(
    List<DecisionCheck> checks, {
    required String clear,
    required String caution,
    required String blocked,
  }) {
    if (checks.any((c) => c.outcome == CheckOutcome.fail)) {
      return CheckSummary.blocked(blocked);
    }
    if (checks.any((c) => c.outcome == CheckOutcome.warn)) {
      return CheckSummary.caution(caution);
    }
    return CheckSummary.clear(clear);
  }
}
