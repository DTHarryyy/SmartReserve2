import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

enum CheckOutcome {
  pass(Icons.check_rounded, SR.greenTint, SR.greenDark, SR.ink3),
  warn(Icons.priority_high_rounded, SR.amberTint, SR.amber, SR.amber),
  fail(Icons.close_rounded, SR.redTint, SR.red, SR.red),
  info(Icons.remove_rounded, SR.dividerSoft, SR.ink4, SR.ink3);

  const CheckOutcome(
    this.mark,
    this.background,
    this.foreground,
    this.valueColor,
  );

  final IconData mark;
  final Color background;
  final Color foreground;
  final Color valueColor;
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

  factory CheckSummary.clear(String text) => CheckSummary(
    text: text,
    background: SR.greenTint,
    borderColor: const Color(0xFFB7E9CD),
    foreground: SR.greenDark,
  );

  factory CheckSummary.caution(String text) => CheckSummary(
    text: text,
    background: SR.amberTint,
    borderColor: SR.amberLine,
    foreground: SR.amber,
  );

  factory CheckSummary.blocked(String text) => CheckSummary(
    text: text,
    background: SR.redTint,
    borderColor: SR.redLine,
    foreground: SR.red,
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
