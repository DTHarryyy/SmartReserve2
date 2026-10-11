import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/push_service.dart';

class _Settings implements NotificationSettings {
  @override
  AuthorizationStatus authorizationStatus = AuthorizationStatus.authorized;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Messaging implements FirebaseMessaging {
  final tokens = StreamController<String>.broadcast(sync: true);
  final settings = _Settings();
  String token = 'first-token';
  int deleted = 0;
  int prompts = 0;
  bool rotateOnDelete = false;
  bool deleteFails = false;

  @override
  Future<NotificationSettings> getNotificationSettings() async => settings;
  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async => token;
  @override
  Stream<String> get onTokenRefresh => tokens.stream;
  @override
  Future<void> deleteToken() async {
    deleted++;
    if (deleteFails) throw StateError('FCM unavailable');
    if (rotateOnDelete) token = 'rotated-$deleted';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #requestPermission) {
      prompts++;
      return Future<NotificationSettings>.value(settings);
    }
    return super.noSuchMethod(invocation);
  }
}

PushService _pushService({
  List<String>? registered,
  List<String>? disabled,
  void Function(PushNotificationPayload payload)? onOpened,
}) => PushService(
  currentUserId: () => 'owner',
  registerToken: ({required token, required platform, deviceLabel}) async =>
      registered?.add(token),
  disableToken: (token) async => disabled?.add(token),
  onForegroundNotification: (_, _, _) {},
  onNotificationOpened: onOpened ?? (_) {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('PushService registration', () {
    late _Messaging messaging;
    late PushService push;
    final saved = <String>[];
    final disabled = <String>[];
    Future<void> Function(String)? save;
    Future<void> Function(String)? disable;
    String? userId;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messaging = _Messaging();
      SharedPreferences.setMockInitialValues({
        'smartreserve.push.owner': 'owner',
        'smartreserve.push.token': 'first-token',
      });
      saved.clear();
      disabled.clear();
      save = null;
      disable = null;
      userId = 'owner';
      push = PushService(
        currentUserId: () => userId,
        messaging: messaging,
        registerToken:
            ({required token, required platform, deviceLabel}) async {
              saved.add(token);
              await save?.call(token);
            },
        disableToken: (token) async {
          disabled.add(token);
          await disable?.call(token);
        },
        onForegroundNotification: (_, _, _) {},
        onNotificationOpened: (_) {},
      );
    });
    tearDown(() async {
      await push.unregister();
      await messaging.tokens.close();
      debugDefaultTargetPlatformOverride = null;
    });

    test('is active only after the backend confirms the token', () async {
      final gate = Completer<void>();
      save = (_) => gate.future;
      final registering = push.registerIfAlreadyGranted();
      await Future<void>.delayed(Duration.zero);
      expect(saved, ['first-token']);
      expect(push.isRegistered, isFalse);
      gate.complete();
      expect(await registering, isTrue);
      expect(push.isRegistered, isTrue);
      expect(messaging.prompts, 0);
    });

    test(
      'signed-out devices never register even with granted permission',
      () async {
        userId = null;
        expect(await push.registerIfAlreadyGranted(), isFalse);
        expect(await push.requestPermissionAndRegister(), isFalse);
        expect(saved, isEmpty);
        expect(messaging.prompts, 0);
        expect(push.isRegistered, isFalse);
      },
    );

    test('logout revokes FCM even when the database disable fails', () async {
      expect(await push.registerIfAlreadyGranted(), isTrue);
      disable = (_) async => throw StateError('database unavailable');
      await push.unregister();
      expect(disabled, ['first-token']);
      expect(messaging.deleted, 1);
      expect(push.isRegistered, isFalse);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('smartreserve.push.owner'), isNull);
    });

    test('logout after restart disables the persisted device token', () async {
      await push.unregister();
      expect(disabled, ['first-token']);
      expect(messaging.deleted, 1);
      expect(saved, isEmpty);
    });

    test(
      'failed FCM revocation is retained for the next cleanup retry',
      () async {
        expect(await push.registerIfAlreadyGranted(), isTrue);
        messaging.deleteFails = true;
        await push.unregister();
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString('smartreserve.push.token'), 'first-token');
        messaging.deleteFails = false;
        await push.unregister();
        expect(messaging.deleted, 2);
        expect(preferences.getString('smartreserve.push.token'), isNull);
        await push.unregister();
        expect(messaging.deleted, 2);
      },
    );

    test(
      'reopening with the same account retains its background token',
      () async {
        expect(await push.registerIfAlreadyGranted(), isTrue);
        await push.dispose();
        push = PushService(
          messaging: messaging,
          currentUserId: () => userId,
          registerToken:
              ({required token, required platform, deviceLabel}) async {
                saved.add(token);
              },
          disableToken: (token) async => disabled.add(token),
          onForegroundNotification: (_, _, _) {},
          onNotificationOpened: (_) {},
        );
        expect(await push.registerIfAlreadyGranted(), isTrue);
        expect(saved, ['first-token', 'first-token']);
        expect(messaging.deleted, 0);
        expect(disabled, isEmpty);
      },
    );

    test(
      'account change replaces the previous account token before saving',
      () async {
        userId = 'new-owner';
        messaging.rotateOnDelete = true;
        expect(await push.registerIfAlreadyGranted(), isTrue);
        expect(messaging.deleted, 1);
        expect(saved, ['rotated-1']);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString('smartreserve.push.owner'), 'new-owner');
        expect(preferences.getString('smartreserve.push.token'), 'rotated-1');
        expect(push.isRegistered, isTrue);
      },
    );

    test(
      'account change cannot reuse an old token if revocation fails',
      () async {
        userId = 'new-owner';
        messaging.deleteFails = true;
        expect(await push.registerIfAlreadyGranted(), isFalse);
        expect(saved, isEmpty);
        expect(push.isRegistered, isFalse);
        messaging.deleteFails = false;
        messaging.rotateOnDelete = true;
        expect(await push.registerIfAlreadyGranted(), isTrue);
        expect(saved, ['rotated-2']);
      },
    );

    test('changing account invalidates a pending registration', () async {
      final gate = Completer<void>();
      save = (_) => gate.future;
      final registering = push.registerIfAlreadyGranted();
      await Future<void>.delayed(Duration.zero);
      userId = 'new-owner';
      gate.complete();
      expect(await registering, isFalse);
      expect(disabled, ['first-token']);
      expect(push.isRegistered, isFalse);
    });

    test('upgrading an untracked device rotates its previous token', () async {
      SharedPreferences.setMockInitialValues({});
      messaging.rotateOnDelete = true;
      expect(await push.registerIfAlreadyGranted(), isTrue);
      expect(messaging.deleted, 1);
      expect(saved, ['rotated-1']);
    });

    test('failed backend registration reports failure and can retry', () async {
      save = (_) async => throw StateError('offline');
      expect(await push.registerIfAlreadyGranted(), isFalse);
      expect(push.isRegistered, isFalse);
      save = null;
      expect(await push.registerIfAlreadyGranted(), isTrue);
      expect(push.isRegistered, isTrue);
    });

    test('refresh failures are handled and recover silently', () async {
      expect(await push.registerIfAlreadyGranted(), isTrue);
      save = (_) async => throw StateError('offline');
      messaging.token = 'refreshed-token';
      messaging.tokens.add(messaging.token);
      await Future<void>.delayed(Duration.zero);
      expect(push.isRegistered, isFalse);
      messaging.tokens.addError(StateError('provider error'));
      save = null;
      expect(await push.registerIfAlreadyGranted(), isTrue);
      expect(saved.last, 'refreshed-token');
      expect(push.isRegistered, isTrue);
    });

    test('concurrent registration saves the device only once', () async {
      final gate = Completer<void>();
      save = (_) => gate.future;
      final first = push.registerIfAlreadyGranted();
      final second = push.registerIfAlreadyGranted();
      await Future<void>.delayed(Duration.zero);
      expect(saved, ['first-token']);
      gate.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
    });

    test(
      'disposal cancels listeners and preserves background device registration',
      () async {
        expect(await push.registerIfAlreadyGranted(), isTrue);
        await push.dispose();
        expect(messaging.tokens.hasListener, isFalse);
        expect(disabled, isEmpty);
        expect(messaging.deleted, 0);
      },
    );

    test(
      'logout waits for a pending token refresh and disables both tokens',
      () async {
        expect(await push.registerIfAlreadyGranted(), isTrue);
        final gate = Completer<void>();
        save = (_) => gate.future;
        messaging.tokens.add('refreshed-token');
        await Future<void>.delayed(Duration.zero);
        final unregistering = push.unregister();
        gate.complete();
        await unregistering;
        expect(disabled.toSet(), {'first-token', 'refreshed-token'});
        expect(push.isRegistered, isFalse);
      },
    );

    test('logout during registration disables the late token', () async {
      final gate = Completer<void>();
      save = (_) => gate.future;
      final registering = push.registerIfAlreadyGranted();
      await Future<void>.delayed(Duration.zero);
      final unregistering = push.unregister();
      gate.complete();
      expect(await registering, isFalse);
      await unregistering;
      expect(disabled, ['first-token']);
      expect(push.isRegistered, isFalse);
    });

    test(
      'permission denial never registers a device or prompts on resume',
      () async {
        messaging.settings.authorizationStatus = AuthorizationStatus.denied;
        expect(await push.registerIfAlreadyGranted(), isFalse);
        expect(saved, isEmpty);
        expect(messaging.prompts, 0);
        expect(await push.requestPermissionAndRegister(), isFalse);
        expect(messaging.prompts, 1);
      },
    );
  });
  group('AppState push wiring', () {
    test(
      'enabling push without a configured PushService reports failure',
      () async {
        final state = AppState();
        expect(state.pushService, isNull);
        expect(await state.enablePushNotifications(), isFalse);
      },
    );

    test('opening a push waits for an authenticated workspace', () {
      final state = AppState();
      expect(state.notificationsOpen, isFalse);
      state.handlePushNotificationOpened(
        const PushNotificationPayload(
          notificationId: 'n1',
          kind: 'reservation_submitted',
          requestId: 'r1',
        ),
      );
      expect(state.notificationsOpen, isFalse);
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
