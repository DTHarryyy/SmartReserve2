import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/main.dart';

class _LifecycleState extends AppState {
  final activity = <bool>[];

  @override
  Future<void> initializeBackend() async {}

  @override
  void setNotificationAppActive(bool active) {
    activity.add(active);
    super.setNotificationAppActive(active);
  }
}

void main() {
  testWidgets('app forwards lifecycle changes to notification recovery', (
    tester,
  ) async {
    final state = _LifecycleState();
    addTearDown(state.dispose);
    await tester.pumpWidget(SmartReserveApp(state: state));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsWidgets);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(state.activity.last, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(state.activity.last, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(state.activity.last, isFalse);
  });
}
