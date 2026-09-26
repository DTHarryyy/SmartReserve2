import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

// The only file in the app that talks to firebase_messaging directly, so the
// rest of the app (AppState, SmartReserveBackend) stays provider-agnostic.
// Wired up through callbacks rather than a direct AppState reference to
// avoid a circular import between the two.
class PushService {
  PushService({
    required this.registerToken,
    required this.disableToken,
    required this.onForegroundNotification,
    required this.onNotificationOpened,
  });

  final Future<void> Function({
    required String token,
    required String platform,
    String? deviceLabel,
  })
  registerToken;
  final Future<void> Function(String token) disableToken;

  /// Called for pushes that arrive while the app is open; the OS does not
  /// display those, so the app shows them itself.
  final void Function(String? title, String? body) onForegroundNotification;
  final void Function(String kind, String? requestId) onNotificationOpened;

  static const _webVapidKey = String.fromEnvironment(
    'FCM_VAPID_KEY',
    defaultValue:
        'BFnIxhWdq1appaiArKxgSzZ6dxOIYV_1wh5qoKohRawFLfeKWeXGJeAtHHvVFNX9'
        'PKRK2YXR5UB5rJ23VI_X3Ks',
  );

  String? _lastToken;
  bool get isRegistered => _lastToken != null;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedAppSubscription;

  bool get isSupported =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  String get _platform => kIsWeb ? 'web' : 'android';

  /// Prompts for OS/browser notification permission and, if granted,
  /// registers this device's FCM token. Callers must gate this behind an
  /// explicit user action (a settings toggle) -- this is the only entry
  /// point that shows a permission prompt.
  Future<bool> requestPermissionAndRegister() async {
    if (!isSupported || (kIsWeb && _webVapidKey.isEmpty)) return false;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (!_isGranted(settings)) return false;
      return await _completeRegistration(messaging);
    } catch (error) {
      debugPrint('Push registration failed: $error');
      return false;
    }
  }

  /// Registers this device only if notification permission was already
  /// granted in an earlier session -- never shows a permission prompt.
  /// Intended for re-registering silently on sign-in.
  Future<bool> registerIfAlreadyGranted() async {
    if (!isSupported || (kIsWeb && _webVapidKey.isEmpty)) return false;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.getNotificationSettings();
      if (!_isGranted(settings)) return false;
      return await _completeRegistration(messaging);
    } catch (error) {
      debugPrint('Push re-registration failed: $error');
      return false;
    }
  }

  bool _isGranted(NotificationSettings settings) =>
      settings.authorizationStatus == AuthorizationStatus.authorized ||
      settings.authorizationStatus == AuthorizationStatus.provisional;

  Future<bool> _completeRegistration(FirebaseMessaging messaging) async {
    final registered = await _fetchAndRegisterToken(messaging);
    if (!registered) return false;

    _tokenRefreshSubscription ??= messaging.onTokenRefresh.listen((token) {
      _lastToken = token;
      unawaited(registerToken(token: token, platform: _platform));
    });
    _foregroundSubscription ??= FirebaseMessaging.onMessage.listen(
      (message) => onForegroundNotification(
        message.notification?.title,
        message.notification?.body,
      ),
    );
    _openedAppSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen(
      _handleOpenedMessage,
    );
    return true;
  }

  /// Call once after startup to route into a notification that launched the
  /// app from a fully terminated state.
  Future<void> handleInitialMessage() async {
    if (!isSupported) return;
    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      if (message != null) _handleOpenedMessage(message);
    } catch (error) {
      debugPrint('Could not read the initial push message: $error');
    }
  }

  Future<void> unregister() async {
    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedAppSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _foregroundSubscription = null;
    _openedAppSubscription = null;

    final token = _lastToken;
    _lastToken = null;
    try {
      if (token != null) await disableToken(token);
      if (isSupported) await FirebaseMessaging.instance.deleteToken();
    } catch (error) {
      debugPrint('Push unregister failed: $error');
    }
  }

  Future<bool> _fetchAndRegisterToken(FirebaseMessaging messaging) async {
    final token = kIsWeb
        ? await messaging.getToken(vapidKey: _webVapidKey)
        : await messaging.getToken();
    if (token == null) return false;
    _lastToken = token;
    await registerToken(token: token, platform: _platform);
    return true;
  }

  void _handleOpenedMessage(RemoteMessage message) {
    final kind = message.data['kind'];
    if (kind is! String || kind.isEmpty) return;
    onNotificationOpened(kind, message.data['request_id'] as String?);
  }
}
