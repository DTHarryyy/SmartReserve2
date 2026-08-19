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
  const ToastMessage(this.text, {this.tone = AdvisoryTone.good, this.action});

  final String text;
  final AdvisoryTone tone;
  final ToastAction? action;
}

@immutable
class UndoOffer {
  const UndoOffer({required this.label, required this.onUndo});

  final String label;
  final VoidCallback onUndo;
}
