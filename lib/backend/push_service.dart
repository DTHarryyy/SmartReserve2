import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class PushNotificationPayload {
  const PushNotificationPayload({
    required this.notificationId,
    required this.kind,
    this.requestId,
  });

  final String notificationId;
  final String kind;
  final String? requestId;
}

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
    required this.currentUserId,
    FirebaseMessaging? messaging,
  }) : _messagingOverride = messaging;

  final FirebaseMessaging? _messagingOverride;
  FirebaseMessaging get _messaging =>
      _messagingOverride ?? FirebaseMessaging.instance;

  final Future<void> Function({
    required String token,
    required String platform,
    String? deviceLabel,
  })
  registerToken;
  final Future<void> Function(String token) disableToken;
  final String? Function() currentUserId;

  /// Called for pushes that arrive while the app is open; the OS does not
  /// display those, so the app shows them itself.
  final void Function(
    PushNotificationPayload payload,
    String? title,
    String? body,
  )
  onForegroundNotification;
  final void Function(PushNotificationPayload payload) onNotificationOpened;

  static const _webVapidKey = String.fromEnvironment(
    'FCM_VAPID_KEY',
    defaultValue:
        'BFnIxhWdq1appaiArKxgSzZ6dxOIYV_1wh5qoKohRawFLfeKWeXGJeAtHHvVFNX9'
        'PKRK2YXR5UB5rJ23VI_X3Ks',
  );

  String? _lastToken;
  String? _registeredUserId;
  bool _revocationRequired = true;
  final _tokensToDisable = <String>{};
  static const _ownerKey = 'smartreserve.push.owner';
  static const _tokenKey = 'smartreserve.push.token';
  static const _requestTimeout = Duration(seconds: 10);
  bool _registrationConfirmed = false;
  bool get isRegistered =>
      _lastToken != null &&
      _registrationConfirmed &&
      _registeredUserId != null &&
      currentUserId() == _registeredUserId;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedAppSubscription;
  Future<bool>? _registration;
  Future<void>? _unregistration;
  Future<bool>? _tokenRefreshSave;
  int _generation = 0;

  bool get isSupported =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  String get _platform => kIsWeb ? 'web' : 'android';

  /// Prompts for OS/browser notification permission and, if granted,
  /// registers this device's FCM token. Callers must gate this behind an
  /// explicit user action (a settings toggle) -- this is the only entry
  /// point that shows a permission prompt.
  Future<bool> requestPermissionAndRegister() => _register(prompt: true);

  /// Registers this device only if notification permission was already
  /// granted in an earlier session -- never shows a permission prompt.
  /// Intended for re-registering silently on sign-in.
  Future<bool> registerIfAlreadyGranted() => _register(prompt: false);

  Future<bool> _register({required bool prompt}) async {
    if (!isSupported || (kIsWeb && _webVapidKey.isEmpty)) return false;
    final userId = currentUserId();
    if (userId == null) return false;
    final generation = _generation;
    await _unregistration;
    if (!_isCurrentAccount(generation, userId)) return false;
    final pending = _registration;
    if (pending != null) return pending;
    final operation = (() async {
      try {
        final messaging = _messaging;
        final settings = prompt
            ? await messaging.requestPermission().timeout(_requestTimeout)
            : await messaging.getNotificationSettings().timeout(
                _requestTimeout,
              );
        if (!_isCurrentAccount(generation, userId)) return false;
        if (!_isGranted(settings)) {
          _registrationConfirmed = false;
          return false;
        }
        return await _completeRegistration(messaging, generation, userId);
      } catch (error) {
        debugPrint('Push registration failed: $error');
        return false;
      }
    })();
    _registration = operation;
    try {
      return await operation;
    } finally {
      if (identical(_registration, operation)) _registration = null;
    }
  }

  bool _isGranted(NotificationSettings settings) =>
      settings.authorizationStatus == AuthorizationStatus.authorized ||
      settings.authorizationStatus == AuthorizationStatus.provisional;

  bool _isCurrentAccount(int generation, String userId) =>
      generation == _generation && currentUserId() == userId;

  Future<bool> _completeRegistration(
    FirebaseMessaging messaging,
    int generation,
    String userId,
  ) async {
    final registered = await _fetchAndRegisterToken(
      messaging,
      generation,
      userId,
    );
    if (!registered) return false;

    _tokenRefreshSubscription ??= messaging.onTokenRefresh.listen(
      (token) {
        if (!_isCurrentAccount(generation, userId)) return;
        _registrationConfirmed = false;
        final previous = _tokenRefreshSave;
        _tokenRefreshSave = (() async {
          await previous;
          if (!_isCurrentAccount(generation, userId)) return false;
          return _saveRefreshedToken(token, generation, userId);
        })();
      },
      onError: (Object error) =>
          debugPrint('Push token refresh failed: $error'),
    );
    _foregroundSubscription ??= FirebaseMessaging.onMessage.listen((message) {
      if (!_isCurrentAccount(generation, userId)) return;
      final payload = _payload(message);
      if (payload == null) return;
      onForegroundNotification(
        payload,
        message.notification?.title,
        message.notification?.body,
      );
    });
    _openedAppSubscription ??= FirebaseMessaging.onMessageOpenedApp.listen((
      message,
    ) {
      if (_isCurrentAccount(generation, userId)) _handleOpenedMessage(message);
    });
    return true;
  }

  /// Call once after startup to route into a notification that launched the
  /// app from a fully terminated state.
  Future<void> handleInitialMessage() async {
    if (!isSupported) return;
    final generation = _generation;
    try {
      final message = await _messaging.getInitialMessage();
      if (generation == _generation && message != null) {
        _handleOpenedMessage(message);
      }
    } catch (error) {
      debugPrint('Could not read the initial push message: $error');
    }
  }

  Future<void> unregister() {
    final pending = _unregistration;
    if (pending != null) return pending;
    if (!_revocationRequired &&
        _registration == null &&
        _tokenRefreshSave == null) {
      return Future.value();
    }
    _generation++;
    final registration = _registration;
    final tokenRefreshSave = _tokenRefreshSave;
    _tokenRefreshSave = null;
    final tokenSubscription = _tokenRefreshSubscription;
    final foregroundSubscription = _foregroundSubscription;
    final openedSubscription = _openedAppSubscription;
    _tokenRefreshSubscription = null;
    _foregroundSubscription = null;
    _openedAppSubscription = null;

    final token = _lastToken;
    _lastToken = null;
    _registrationConfirmed = false;
    _registeredUserId = null;
    final operation = (() async {
      await tokenSubscription?.cancel();
      await foregroundSubscription?.cancel();
      await openedSubscription?.cancel();
      await registration;
      await tokenRefreshSave;
      if (!isSupported) return;
      SharedPreferences? preferences;
      try {
        preferences = await SharedPreferences.getInstance();
        final persistedToken = preferences.getString(_tokenKey);
        if (persistedToken != null) _tokensToDisable.add(persistedToken);
      } catch (error) {
        debugPrint('Push device ownership could not be loaded: $error');
      }
      if (token != null) _tokensToDisable.add(token);
      if (_tokensToDisable.isEmpty &&
          token == null &&
          registration == null &&
          tokenRefreshSave == null) {
        // Covers tokens created by an earlier version or before this service
        // was initialized. Retrieving an existing token never prompts.
        try {
          final settings = await _messaging.getNotificationSettings().timeout(
            _requestTimeout,
          );
          if (_isGranted(settings)) {
            final existing = await _messaging
                .getToken(vapidKey: kIsWeb ? _webVapidKey : null)
                .timeout(_requestTimeout);
            if (existing != null) _tokensToDisable.add(existing);
          }
        } catch (error) {
          debugPrint('Previous push token could not be loaded: $error');
        }
      }
      for (final staleToken in _tokensToDisable.toList()) {
        try {
          await disableToken(staleToken).timeout(_requestTimeout);
          _tokensToDisable.remove(staleToken);
        } catch (error) {
          debugPrint('Push device could not be disabled: $error');
        }
      }
      // FCM revocation must still run if the database request fails or the
      // login session has expired. Never leave it in the same catch block.
      try {
        await _messaging.deleteToken().timeout(_requestTimeout);
        _revocationRequired = false;
        _tokensToDisable.clear();
        await preferences?.remove(_ownerKey);
        await preferences?.remove(_tokenKey);
      } catch (error) {
        debugPrint('Push token could not be revoked: $error');
      }
    })();
    _unregistration = operation;
    return operation.whenComplete(() => _unregistration = null);
  }

  /// Stops app listeners while leaving the device enabled for background push.
  Future<void> dispose() async {
    _generation++;
    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedAppSubscription?.cancel();
    _tokenRefreshSubscription = null;
    _foregroundSubscription = null;
    _openedAppSubscription = null;
  }

  Future<bool> _saveRefreshedToken(
    String token,
    int generation,
    String userId,
  ) async {
    if (!_isCurrentAccount(generation, userId)) return false;
    _revocationRequired = true;
    _tokensToDisable.add(token);
    try {
      await registerToken(
        token: token,
        platform: _platform,
      ).timeout(_requestTimeout);
      if (!_isCurrentAccount(generation, userId)) {
        if (_unregistration == null) {
          await disableToken(token).timeout(_requestTimeout);
          _tokensToDisable.remove(token);
        }
        return false;
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_ownerKey, userId);
      await preferences.setString(_tokenKey, token);
      if (!_isCurrentAccount(generation, userId)) return false;
      _lastToken = token;
      _registeredUserId = userId;
      _registrationConfirmed = true;
      return true;
    } catch (error) {
      debugPrint('Push token could not be saved: $error');
      return false;
    }
  }

  Future<bool> _fetchAndRegisterToken(
    FirebaseMessaging messaging,
    int generation,
    String userId,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    if (!_isCurrentAccount(generation, userId)) return false;
    if (preferences.getString(_ownerKey) != userId) {
      // Tokens belong to an installation, not a login. Rotate before another
      // account can use this installation, including after an app restart.
      await messaging.deleteToken().timeout(_requestTimeout);
      if (!_isCurrentAccount(generation, userId)) return false;
      await preferences.remove(_ownerKey);
      await preferences.remove(_tokenKey);
    }
    _revocationRequired = true;
    final token = kIsWeb
        ? await messaging
              .getToken(vapidKey: _webVapidKey)
              .timeout(_requestTimeout)
        : await messaging.getToken().timeout(_requestTimeout);
    if (token == null || !_isCurrentAccount(generation, userId)) return false;
    return _saveRefreshedToken(token, generation, userId);
  }

  void _handleOpenedMessage(RemoteMessage message) {
    final payload = _payload(message);
    if (payload != null) onNotificationOpened(payload);
  }

  PushNotificationPayload? _payload(RemoteMessage message) {
    final id = message.data['notification_id'];
    final kind = message.data['kind'];
    if (id is! String || id.isEmpty || kind is! String || kind.isEmpty) {
      return null;
    }
    final requestId = message.data['request_id'];
    return PushNotificationPayload(
      notificationId: id,
      kind: kind,
      requestId: requestId is String && requestId.isNotEmpty ? requestId : null,
    );
  }
}
