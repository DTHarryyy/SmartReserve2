// Background service worker for web push. Auto-registered by
// firebase_messaging_web at /firebase-messaging-sw.js -- no manual
// registration in index.html needed. A service worker can't read Dart's
// --dart-define values, so this config is plain JS, duplicating the
// defaults in lib/main.dart for the same Firebase project
// (smartreserve-48784). Update both together if the project ever changes.
importScripts("https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDTH-IQXefaw1hV6CFVTHMBbdjMXCKyzN4",
  authDomain: "smartreserve-48784.firebaseapp.com",
  projectId: "smartreserve-48784",
  storageBucket: "smartreserve-48784.firebasestorage.app",
  messagingSenderId: "428216422364",
  appId: "1:428216422364:web:d827a9e738cd91f01d8919",
});

// Registered before firebase.messaging() so it runs ahead of the SDK's own
// click handler, which only acts on an fcm_options.link we don't send.
// An open SmartReserve tab is focused (its realtime feed already shows the
// notification); otherwise a new tab opens with the push's routing data in
// the query string, which lib/main.dart replays once the session loads.
self.addEventListener("notificationclick", (event) => {
  const payload = event.notification?.data?.FCM_MSG?.data ?? {};
  event.notification.close();
  event.stopImmediatePropagation();

  const params = new URLSearchParams();
  if (payload.kind) params.set("push_kind", payload.kind);
  if (payload.request_id) params.set("push_request", payload.request_id);
  if (payload.notification_id) {
    params.set("push_notification", payload.notification_id);
  }
  const scope = self.registration.scope;
  const target = params.toString() ? `${scope}?${params}` : scope;

  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((windows) => {
        const open = windows.find((client) => client.url.startsWith(scope));
        if (open) {
          open.postMessage({ type: "smartreserve-push-open", ...payload });
          return open.focus();
        }
        return self.clients.openWindow(target);
      }),
  );
});

firebase.messaging();
