import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/push_service.dart';

PushService _pushService({
  List<String>? registered,
  List<String>? disabled,
  void Function(String kind, String? requestId)? onOpened,
}) => PushService(
  registerToken: ({required token, required platform, deviceLabel}) async =>
      registered?.add(token),
  disableToken: (token) async => disabled?.add(token),
  onForegroundNotification: (_, _) {},
  onNotificationOpened: onOpened ?? (_, _) {},
);

void main() {
  group('AppState push wiring', () {
    test('enabling push without a configured PushService reports failure', () async {
      final state = AppState();
      expect(state.pushService, isNull);
      expect(await state.enablePushNotifications(), isFalse);
    });

    test('opening a push notification opens the notifications panel', () {
      final state = AppState();
      expect(state.notificationsOpen, isFalse);
      state.handlePushNotificationOpened('reservation_submitted', 'r1');
      expect(state.notificationsOpen, isTrue);
    });
  });

  group('PushService on an unsupported platform', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('never registers a token or touches Firebase', () async {
      final registered = <String>[];
      final push = _pushService(registered: registered);

      expect(push.isSupported, isFalse);
      expect(await push.requestPermissionAndRegister(), isFalse);
      expect(await push.registerIfAlreadyGranted(), isFalse);
      expect(push.isRegistered, isFalse);
      expect(registered, isEmpty);
    });

    test('unregister without a token does not call disableToken', () async {
      final disabled = <String>[];
      final push = _pushService(disabled: disabled);

      await push.unregister();
      expect(disabled, isEmpty);
      expect(push.isRegistered, isFalse);
    });
  });
}
