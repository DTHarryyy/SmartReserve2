// Web-only glue between web/firebase-messaging-sw.js and the app: a clicked
// background notification either focuses an open tab (service worker
// postMessage) or opens a new one with the routing data in the query string.
// Other platforms get these no-op stubs; FlutterFire's onMessageOpenedApp /
// getInitialMessage already cover Android.
export 'push_web_bridge_stub.dart'
    if (dart.library.js_interop) 'push_web_bridge_web.dart';

typedef PushOpenHandler =
    void Function(String kind, String? requestId, String? notificationId);
