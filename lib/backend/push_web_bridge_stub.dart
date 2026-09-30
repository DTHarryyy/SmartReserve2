import 'push_web_bridge.dart';

/// Push routing data the app was launched with, if any.
({String kind, String? requestId, String? notificationId})?
consumeLaunchPushOpen() => null;

/// Starts listening for notification clicks relayed to an already-open tab.
void listenForPushClicks(PushOpenHandler onOpen) {}
