import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'push_web_bridge.dart';

/// Reads (and strips from the address bar, so a reload doesn't re-route) the
/// push routing data the service worker put in the query string.
({String kind, String? requestId, String? notificationId})?
consumeLaunchPushOpen() {
  final uri = Uri.base;
  final kind = uri.queryParameters['push_kind'];
  if (kind == null || kind.isEmpty) return null;
  final cleaned = uri.replace(
    queryParameters: {
      for (final entry in uri.queryParameters.entries)
        if (!entry.key.startsWith('push_')) entry.key: entry.value,
    },
  );
  final path = cleaned.query.isEmpty
      ? cleaned.path
      : '${cleaned.path}?${cleaned.query}';
  web.window.history.replaceState(
    null,
    '',
    cleaned.hasFragment ? '$path#${cleaned.fragment}' : path,
  );
  return (
    kind: kind,
    requestId: uri.queryParameters['push_request'],
    notificationId: uri.queryParameters['push_notification'],
  );
}

void listenForPushClicks(PushOpenHandler onOpen) {
  // navigator.serviceWorker is absent on insecure origins; push can't work
  // there anyway, so there is nothing to listen for.
  try {
    _listen(onOpen);
  } catch (_) {}
}

void _listen(PushOpenHandler onOpen) {
  web.window.navigator.serviceWorker.addEventListener(
    'message',
    ((web.MessageEvent event) {
      final data = event.data.dartify();
      if (data is! Map || data['type'] != 'smartreserve-push-open') return;
      final kind = data['kind'];
      if (kind is! String || kind.isEmpty) return;
      final requestId = data['request_id'];
      final notificationId = data['notification_id'];
      onOpen(
        kind,
        requestId is String ? requestId : null,
        notificationId is String ? notificationId : null,
      );
    }).toJS,
  );
}
