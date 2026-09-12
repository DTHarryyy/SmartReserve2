import 'package:flutter/foundation.dart';

mixin SafeChangeNotifier on ChangeNotifier {
  bool _srDisposed = false;
  bool get isDisposed => _srDisposed;

  @override
  void notifyListeners() {
    if (_srDisposed) return;
    super.notifyListeners();
  }

  @mustCallSuper
  @override
  void dispose() {
    _srDisposed = true;
    super.dispose();
  }
}
