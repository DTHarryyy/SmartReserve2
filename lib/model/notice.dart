import 'package:flutter/foundation.dart';

enum AdvisoryTone { good, info, warn, block }

@immutable
class ToastMessage {
  const ToastMessage(this.text, {this.tone = AdvisoryTone.good});

  final String text;
  final AdvisoryTone tone;
}

@immutable
class UndoOffer {
  const UndoOffer({required this.label, required this.onUndo});

  final String label;
  final VoidCallback onUndo;
}
