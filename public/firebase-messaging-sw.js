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

firebase.messaging();
