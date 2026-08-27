import 'dart:async';

import 'package:flutter/foundation.dart';

import '../model/notice.dart';

@immutable
class ActiveToast {
  const ActiveToast({required this.id, required this.message});

  final int id;
  final ToastMessage message;
}

/// Owns the application's single transient-feedback slot.
class SrToastController extends ChangeNotifier {
  ActiveToast? _active;
  Timer? _timer;
  var _nextId = 0;
  var _disposed = false;

  ActiveToast? get active => _active;

  void show(ToastMessage message, {Duration? duration}) {
    if (_disposed) return;
    _timer?.cancel();
    final entry = ActiveToast(id: ++_nextId, message: message);
    _active = entry;
    notifyListeners();

    final timeout = duration ?? message.duration ?? _defaultDuration(message);
    _timer = Timer(timeout, () => dismiss(id: entry.id));
  }

  void dismiss({int? id}) {
    if (id != null && _active?.id != id) return;
    if (_active == null) return;
    _timer?.cancel();
    _timer = null;
    _active = null;
    if (!_disposed) notifyListeners();
  }

  void invokeAction() {
    if (_disposed) return;
    final action = _active?.message.action;
    if (action == null) return;
    dismiss();
    action.onPressed();
  }

  Duration _defaultDuration(ToastMessage message) {
    if (message.action != null) return const Duration(seconds: 8);
    return switch (message.tone) {
      AdvisoryTone.good || AdvisoryTone.info => const Duration(seconds: 4),
      AdvisoryTone.warn || AdvisoryTone.block => const Duration(seconds: 6),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _active = null;
    super.dispose();
  }
}
