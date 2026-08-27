import 'package:flutter/foundation.dart';

enum AdvisoryTone { good, info, warn, block }

@immutable
class ToastAction {
  const ToastAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

@immutable
class ToastMessage {
  const ToastMessage(this.text, {
    this.tone = AdvisoryTone.good,
    this.action,
    this.duration,
  });

  const ToastMessage.success(
    String text, {
    ToastAction? action,
    Duration? duration,
  }) : this(text, tone: AdvisoryTone.good, action: action, duration: duration);

  const ToastMessage.info(
    String text, {
    ToastAction? action,
    Duration? duration,
  }) : this(text, tone: AdvisoryTone.info, action: action, duration: duration);

  const ToastMessage.warning(
    String text, {
    ToastAction? action,
    Duration? duration,
  }) : this(text, tone: AdvisoryTone.warn, action: action, duration: duration);

  const ToastMessage.error(
    String text, {
    ToastAction? action,
    Duration? duration,
  }) : this(text, tone: AdvisoryTone.block, action: action, duration: duration);

  final String text;
  final AdvisoryTone tone;
  final ToastAction? action;
  final Duration? duration;
}
