import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/push_service.dart';
import 'package:smartreserve/backend/realtime_changes.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/model/anomaly.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SessionProfile _profile(String id, {String role = 'user'}) => SessionProfile(
  id: id,
  email: '$id@example.com',
  fullName: id,
  role: role,
  campusClaim: null,
  campusId: null,
  unit: null,
  verificationStatus: 'none',
  onboardingComplete: true,
  accountStatus: 'active',
  accountAccessType: 'external_guest',
  mustChangePassword: false,
  createdAt: null,
);

BackendNotification _row(String id, {int minute = 0}) => BackendNotification(
  id: id,
  kind: 'test',
  title: 'Notification $id',
  body: 'New update',
  createdAt: DateTime.utc(2026, 10, 11, 0, minute),
);

const _payload = PushNotificationPayload(notificationId: 'push', kind: 'test');

class _Backend implements SmartReserveBackend {
  final auth = StreamController<AuthState>.broadcast(sync: true);
  @override
  Stream<AuthState> get authChanges => auth.stream;
  @override
  User? user;
  SessionProfile? profile;
  Future<void> Function()? signingOut;
  @override
  Future<SessionProfile?> currentProfile() async => profile;
  @override
  Future<void> signOut() async => await signingOut?.call();
  final channels = <StreamController<RowDelta<BackendNotification>>>[];
  List<BackendNotification> rows = [];
  Future<List<BackendNotification>> Function()? fetch;
  Future<BackendNotification?> Function(String)? lookup;
  Future<Map<String, bool>> Function()? preferences;
  Future<void> Function(String)? markRead;
  Future<BackendVerification?>? verification;
  int fetches = 0;
  int activeFetches = 0;
  int maxActiveFetches = 0;
  int preferenceFetches = 0;

  void emit(RowDelta<BackendNotification> delta) => channels.last.add(delta);

  @override
  Stream<RowDelta<BackendNotification>> notificationChanges() {
    final channel = StreamController<RowDelta<BackendNotification>>(sync: true);
    channels.add(channel);
    return channel.stream;
  }

  @override
  Future<List<BackendNotification>> unreadNotifications() async {
    fetches++;
    activeFetches++;
    if (activeFetches > maxActiveFetches) maxActiveFetches = activeFetches;
    try {
      return fetch == null ? List.of(rows) : await fetch!();
    } finally {
      activeFetches--;
    }
  }

  @override
  Future<Map<String, bool>> notificationPreferences() async {
    preferenceFetches++;
    return preferences == null
        ? {'Decision on my requests': true}
        : await preferences!();
  }

  @override
  Future<void> saveNotificationPreferences(Map<String, bool> _) async {}

  @override
  Future<void> markNotificationRead(String id) async {
    if (markRead != null) {
      await markRead!(id);
    } else {
      rows.removeWhere((row) => row.id == id);
    }
  }

  @override
  Future<BackendNotification?> notificationById(String id) async =>
      lookup == null
      ? rows.where((row) => row.id == id).firstOrNull
      : await lookup!(id);

  @override
  Future<BackendVerification?> currentVerification() async =>
      await verification;

  @override
  Future<void> generateReservationReminders() async {}

  @override
  Stream<List<BackendFacility>> facilityStream() => const Stream.empty();

  @override
  Stream<RowDelta<BackendReservation>> reservationChanges() =>
      const Stream.empty();

  @override
  Stream<List<BackendAccount>> accountStream() => const Stream.empty();

  @override
  Stream<void> verificationChanges() => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

class _State extends AppState {
  bool disposed = false;
  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }

  _State() : super(useDemoData: false);
  Future<void>? facilityGate;

  @override
  Future<void> refreshFacilities() async => await facilityGate;
  @override
  Future<void> refreshReservations() async {}
  @override
  Future<void> refreshAccounts() async {}
  @override
  Future<void> refreshVerifications() async {}
  @override
  Future<void> refreshLoyalty() async {}
  @override
  Future<void> refreshAnomalyCenter({AnomalyFilters? filters}) async {}
}

class _Push extends PushService {
  _Push()
    : super(
        currentUserId: () => 'owner',
        registerToken:
            ({required token, required platform, deviceLabel}) async {},
        disableToken: (_) async {},
        onForegroundNotification: (_, _, _) {},
        onNotificationOpened: (_) {},
      );
  int registrations = 0;
  Future<void> Function()? unregistering;
  int unregistrations = 0;
  @override
  Future<void> unregister() async {
    unregistrations++;
    await unregistering?.call();
  }

  @override
  Future<bool> registerIfAlreadyGranted() async {
    registrations++;
    return true;
  }
}

void main() {
  late _Backend backend;
  late _State state;
  setUp(() {
    backend = _Backend();
    state = _State();
  });
  tearDown(() async {
    state.dispose();
    for (final channel in backend.channels) {
      await channel.close();
    }
    await backend.auth.close();
  });

  void scenario(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      state.configureBackend(backend);
      try {
        await body(tester);
      } finally {
        state.dispose();
      }
    });
  }

  Future<void> signIn({String role = 'user'}) async {
    await state.applyBackendProfile(_profile('owner', role: role));
    await state.workspaceReady;
  }

  for (final role in ['user', 'internal_admin', 'external_admin']) {
    scenario('$role receives immediately before other workspace loads finish', (
      tester,
    ) async {
      final gate = Completer<void>();
      state.facilityGate = gate.future;
      await state.applyBackendProfile(_profile('owner', role: role));
      expect(state.workspaceLoading, isTrue);
      backend.emit(RowDelta.patch(upserts: [_row('live')], removedIds: {}));
      await tester.pump();
      expect(state.notifications.single.id, 'live');
      expect(state.unreadNotifications, 1);
      gate.complete();
      await state.workspaceReady;
    });
  }

  scenario('subscribes before renter verification finishes', (tester) async {
    final gate = Completer<BackendVerification?>();
    backend.verification = gate.future;
    final signingIn = state.applyBackendProfile(_profile('owner'));
    expect(backend.channels, hasLength(1));
    backend.emit(RowDelta.patch(upserts: [_row('early')], removedIds: {}));
    await tester.pump();
    expect(state.notifications.single.id, 'early');
    gate.complete(null);
    await signingIn;
    await state.workspaceReady;
  });

  scenario(
    'deduplicates, orders and caps changes while inbox is open or closed',
    (tester) async {
      await signIn();
      for (final open in [false, true]) {
        state.notificationsOpen = open;
        final rows = [for (var i = 0; i < 105; i++) _row('n$i', minute: i)];
        backend.emit(
          RowDelta.patch(
            upserts: [...rows.reversed, rows.first],
            removedIds: {},
          ),
        );
        await tester.pump();
        expect(state.notifications, hasLength(100));
        expect(state.notifications.first.id, 'n104');
        expect(state.notifications.last.id, 'n5');
        expect(
          state.notifications.map((row) => row.id).toSet(),
          hasLength(100),
        );
      }
    },
  );

  scenario('cross-device read and removal update badge immediately', (
    tester,
  ) async {
    backend.rows = [_row('a'), _row('b')];
    await signIn();
    backend.emit(
      RowDelta.patch(
        upserts: [_row('a').markedRead(DateTime.utc(2026))],
        removedIds: {'b'},
      ),
    );
    await tester.pump();
    expect(state.unreadNotifications, 0);
  });

  scenario('polls every ten seconds, pauses and refreshes on resume', (
    tester,
  ) async {
    await signIn();
    final push = _Push();
    state.configurePush(push);
    await tester.pump();
    backend.rows = [_row('missed')];
    await tester.pump(const Duration(seconds: 9));
    expect(state.notifications, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(state.notifications.single.id, 'missed');
    final calls = backend.fetches;
    state.setNotificationAppActive(false);
    backend.rows = [_row('background')];
    await tester.pump(const Duration(seconds: 30));
    expect(backend.fetches, calls);
    state.setNotificationAppActive(true);
    await tester.pump();
    expect(state.notifications.single.id, 'background');
    expect(push.registrations, 2);
  });

  scenario('opening inbox refreshes without waiting for polling', (
    tester,
  ) async {
    await signIn();
    backend.rows = [_row('missed')];
    state.toggleNotifications();
    await tester.pump();
    expect(state.notificationsOpen, isTrue);
    expect(state.notifications.single.id, 'missed');
  });

  scenario('silent polling keeps an already loaded empty inbox visible', (
    tester,
  ) async {
    await signIn();
    final gate = Completer<List<BackendNotification>>();
    backend.fetch = () => gate.future;
    final refreshing = state.refreshNotifications(silent: true);
    expect(state.notificationsLoading, isFalse);
    gate.complete([]);
    await refreshing;
  });

  scenario(
    'reconnect read snapshot cannot be resurrected by a late push lookup',
    (tester) async {
      backend.rows = [_row('push')];
      await signIn();
      final gate = Completer<BackendNotification?>();
      backend.lookup = (_) => gate.future;
      final receiving = state.handleForegroundPushNotification(
        _payload,
        null,
        null,
      );
      backend.emit(
        RowDelta.replace([_row('push').markedRead(DateTime.utc(2026))]),
      );
      await tester.pump();
      gate.complete(_row('push'));
      await receiving;
      expect(state.notifications, isEmpty);
    },
  );

  scenario(
    'late preferences from a previous account cannot update the new session',
    (tester) async {
      final gate = Completer<Map<String, bool>>();
      backend.preferences = () => gate.future;
      await signIn();
      backend.preferences = () async => {'Decision on my requests': false};
      await state.applyBackendProfile(_profile('new-owner'));
      await state.workspaceReady;
      gate.complete({'Decision on my requests': true});
      await tester.pump();
      expect(state.notificationPreferences['Decision on my requests'], isFalse);
    },
  );

  scenario('stale fetch cannot overwrite a live arrival or read', (
    tester,
  ) async {
    backend.rows = [_row('old')];
    await signIn();
    final gate = Completer<List<BackendNotification>>();
    backend.fetch = () => gate.future;
    final refresh = state.refreshNotifications(silent: true);
    backend.emit(
      RowDelta.patch(
        upserts: [
          _row('new', minute: 1),
          _row('old').markedRead(DateTime.utc(2026)),
        ],
        removedIds: {},
      ),
    );
    await tester.pump();
    gate.complete([_row('old')]);
    await refresh;
    expect(state.notifications.map((row) => row.id), ['new']);
  });

  scenario('concurrent refresh requests serialize with one trailing fetch', (
    tester,
  ) async {
    await signIn();
    final gate = Completer<List<BackendNotification>>();
    var calls = 0;
    backend.fetch = () async {
      calls++;
      return calls == 1 ? await gate.future : [_row('fresh')];
    };
    final first = state.refreshNotifications(silent: true);
    final second = state.refreshNotifications(silent: true);
    state.refreshNotifications(silent: true);
    expect(identical(first, second), isTrue);
    gate.complete([]);
    await first;
    expect(calls, 2);
    expect(backend.maxActiveFetches, 1);
    expect(state.notifications.single.id, 'fresh');
  });

  scenario('reconnect replacement catches up and removes read notifications', (
    tester,
  ) async {
    backend.rows = [_row('old')];
    await signIn();
    backend.emit(RowDelta.replace([_row('reconnected')]));
    await tester.pump();
    expect(state.notifications.single.id, 'reconnected');
  });

  scenario('preference failures do not block inbox and retry on polling', (
    tester,
  ) async {
    backend.preferences = () async => throw StateError('preferences offline');
    backend.rows = [_row('available')];
    await signIn();
    expect(state.notifications.single.id, 'available');
    expect(state.notificationsError, isNull);
    backend.preferences = () async => {'Decision on my requests': false};
    await tester.pump(const Duration(seconds: 10));
    expect(state.notificationPreferences['Decision on my requests'], isFalse);
    expect(backend.preferenceFetches, 2);
    await tester.pump(const Duration(seconds: 10));
    expect(backend.preferenceFetches, 2);
  });

  scenario('late preferences preserve a setting changed locally', (
    tester,
  ) async {
    final gate = Completer<Map<String, bool>>();
    backend.preferences = () => gate.future;
    await signIn();
    state.setNotificationPreference('Decision on my requests', false);
    gate.complete({'Decision on my requests': true});
    await tester.pump();
    expect(state.notificationPreferences['Decision on my requests'], isFalse);
  });

  scenario('failed fetch retains inbox and automatically recovers', (
    tester,
  ) async {
    backend.rows = [_row('retained')];
    await signIn();
    backend.fetch = () async => throw StateError('offline');
    await state.refreshNotifications(silent: true);
    expect(state.notifications.single.id, 'retained');
    expect(state.notificationsError, isNotNull);
    backend.fetch = null;
    backend.rows = [_row('recovered')];
    await tester.pump(const Duration(seconds: 10));
    expect(state.notifications.single.id, 'recovered');
    expect(state.notificationsError, isNull);
  });

  scenario('stalled refresh times out and polling ignores its late result', (
    tester,
  ) async {
    backend.rows = [_row('retained')];
    await signIn();
    final gate = Completer<List<BackendNotification>>();
    backend.fetch = () => gate.future;
    final refresh = state.refreshNotifications(silent: true);
    backend.fetch = null;
    backend.rows = [_row('recovered')];
    await tester.pump(const Duration(seconds: 10));
    await refresh;
    // The poll either queues a trailing request or begins after the timeout.
    await tester.pump(const Duration(seconds: 10));
    expect(state.notifications.single.id, 'recovered');
    expect(state.notificationsLoading, isFalse);
    gate.complete([_row('stale')]);
    await tester.pump();
    expect(state.notifications.single.id, 'recovered');
  });

  scenario('stalled preferences time out and retry without delaying inbox', (
    tester,
  ) async {
    final gate = Completer<Map<String, bool>>();
    backend.preferences = () => gate.future;
    backend.rows = [_row('available')];
    await signIn();
    expect(state.notifications.single.id, 'available');
    backend.preferences = () async => {'Decision on my requests': false};
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(backend.preferenceFetches, 2);
    expect(state.notificationPreferences['Decision on my requests'], isFalse);
    gate.complete({'Decision on my requests': true});
    await tester.pump();
    expect(state.notificationPreferences['Decision on my requests'], isFalse);
  });

  scenario('stalled foreground lookup times out and reconciles the inbox', (
    tester,
  ) async {
    await signIn();
    final gate = Completer<BackendNotification?>();
    backend.lookup = (_) => gate.future;
    backend.rows = [_row('push')];
    final receiving = state.handleForegroundPushNotification(
      _payload,
      null,
      null,
    );
    await tester.pump(const Duration(seconds: 10));
    await receiving;
    expect(state.notifications.single.id, 'push');
    gate.complete(_row('stale'));
    await tester.pump();
    expect(state.notifications.single.id, 'push');
  });

  scenario('stream error reconciles and closed stream restarts on polling', (
    tester,
  ) async {
    await signIn();
    backend.rows = [_row('after-error')];
    backend.channels.last.addError(StateError('channel offline'));
    await tester.pump();
    expect(state.notifications.single.id, 'after-error');
    unawaited(backend.channels.last.close());
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(backend.channels, hasLength(2));
    backend.emit(
      RowDelta.patch(upserts: [_row('new-channel', minute: 1)], removedIds: {}),
    );
    await tester.pump();
    expect(state.notifications.first.id, 'new-channel');
  });

  scenario(
    'foreground push fetches notification without realtime and deduplicates',
    (tester) async {
      await signIn();
      backend.rows = [_row('push')];
      await state.handleForegroundPushNotification(
        _payload,
        'Update',
        'Received',
      );
      expect(state.notifications.single.id, 'push');
      backend.emit(RowDelta.patch(upserts: [_row('push')], removedIds: {}));
      await tester.pump();
      expect(state.unreadNotifications, 1);
    },
  );

  scenario('push for another account cannot show its toast or inbox row', (
    tester,
  ) async {
    await signIn();
    backend.lookup = (_) async => null;
    await state.handleForegroundPushNotification(
      _payload,
      'Private old title',
      'Private old body',
    );
    expect(state.notifications, isEmpty);
    expect(state.toasts.active, isNull);
  });

  scenario('signed-out push receipt cannot show a toast or fetch inbox', (
    tester,
  ) async {
    final push = _Push();
    state.configurePush(push);
    expect(await state.enablePushNotifications(), isFalse);
    await state.handleForegroundPushNotification(
      _payload,
      'Old title',
      'Old body',
    );
    expect(state.toasts.active, isNull);
    expect(backend.fetches, 0);
    expect(push.registrations, 0);
    expect(push.unregistrations, 1);
  });

  scenario('logout revokes push before clearing backend authentication', (
    tester,
  ) async {
    await signIn();
    final push = _Push();
    state.configurePush(push);
    final order = <String>[];
    final gate = Completer<void>();
    push.unregistering = () async {
      order.add('revoke-push');
      await gate.future;
    };
    backend.signingOut = () async => order.add('sign-out');
    final signingOut = state.signOut();
    await tester.pump();
    expect(order, ['revoke-push']);
    state.setNotificationAppActive(false);
    state.setNotificationAppActive(true);
    await tester.pump();
    expect(push.registrations, 1);
    gate.complete();
    await signingOut;
    expect(order, ['revoke-push', 'sign-out']);
    expect(push.unregistrations, 1);
    expect(state.hasSession, isFalse);
  });

  scenario(
    'expired authentication clears notifications and revokes the device',
    (tester) async {
      backend.rows = [_row('old')];
      await signIn();
      final push = _Push();
      state.configurePush(push);
      backend.auth.add(const AuthState(AuthChangeEvent.signedOut, null));
      await tester.pump();
      expect(state.hasSession, isFalse);
      expect(state.notifications, isEmpty);
      expect(push.unregistrations, 1);
      final calls = backend.fetches;
      await tester.pump(const Duration(seconds: 20));
      expect(backend.fetches, calls);
    },
  );

  scenario('failed foreground lookup reconciles inbox', (tester) async {
    await signIn();
    backend.lookup = (_) async => throw StateError('lookup unavailable');
    backend.rows = [_row('push')];
    await state.handleForegroundPushNotification(_payload, null, null);
    expect(state.notifications.single.id, 'push');
  });

  scenario('authentication account switch drops old subscription and inbox', (
    tester,
  ) async {
    backend.rows = [_row('old-owner')];
    await signIn();
    final push = _Push();
    state.configurePush(push);
    backend.profile = _profile('new-owner');
    backend.user = User(
      id: 'new-owner',
      appMetadata: {},
      userMetadata: {},
      aud: 'authenticated',
      createdAt: '2026-10-11T00:00:00Z',
    );
    backend.rows = [_row('new-owner')];
    backend.auth.add(
      AuthState(
        AuthChangeEvent.signedIn,
        Session(accessToken: 'test', tokenType: 'bearer', user: backend.user!),
      ),
    );
    await tester.pump();
    await state.workspaceReady;
    expect(state.sessionProfile?.id, 'new-owner');
    expect(state.notifications.single.id, 'new-owner');
    expect(backend.channels.first.hasListener, isFalse);
    expect(push.unregistrations, 1);
    expect(push.registrations, 2);
  });

  scenario(
    'optimistic read survives stale snapshots and rolls back on failure',
    (tester) async {
      final row = _row('read');
      backend.rows = [row];
      await signIn();
      final mark = Completer<void>();
      backend.markRead = (_) => mark.future;
      final opening = state.openNotification(row);
      expect(state.notifications, isEmpty);
      await state.refreshNotifications(silent: true);
      backend.emit(RowDelta.replace([row]));
      await tester.pump();
      expect(state.notifications, isEmpty);
      mark.completeError(StateError('write failed'));
      await opening;
      expect(state.notifications.single.id, 'read');
    },
  );

  scenario('successful read remains hidden while old snapshots arrive', (
    tester,
  ) async {
    final row = _row('read');
    backend.rows = [row];
    await signIn();
    backend.markRead = (_) async {};
    await state.openNotification(row);
    await state.refreshNotifications(silent: true);
    backend.emit(RowDelta.replace([row]));
    await tester.pump();
    expect(state.notifications, isEmpty);
  });

  scenario(
    'account switch rejects old fetch, push, preferences and read rollback',
    (tester) async {
      final row = _row('old-owner');
      backend.rows = [row];
      await signIn();
      final fetch = Completer<List<BackendNotification>>();
      final push = Completer<BackendNotification?>();
      final mark = Completer<void>();
      backend.fetch = () => fetch.future;
      backend.lookup = (_) => push.future;
      backend.markRead = (_) => mark.future;
      final refreshing = state.refreshNotifications(silent: true);
      final pushing = state.handleForegroundPushNotification(
        _payload,
        null,
        null,
      );
      final opening = state.openNotification(row);
      backend.fetch = null;
      backend.rows = [_row('new-owner')];
      await state.applyBackendProfile(_profile('new-owner'));
      await state.workspaceReady;
      fetch.complete([row]);
      push.complete(_row('push'));
      mark.completeError(StateError('old write failed'));
      await Future.wait([refreshing, pushing, opening]);
      expect(state.notifications.single.id, 'new-owner');
      expect(state.notificationActionsPending, isEmpty);
      expect(backend.channels.first.hasListener, isFalse);
    },
  );

  scenario('logout cancels polling and ignores pending inbox work', (
    tester,
  ) async {
    await signIn();
    final gate = Completer<List<BackendNotification>>();
    backend.fetch = () => gate.future;
    final refresh = state.refreshNotifications(silent: true);
    await state.applyBackendProfile(null);
    gate.complete([_row('old')]);
    await refresh;
    final calls = backend.fetches;
    await tester.pump(const Duration(seconds: 30));
    expect(backend.fetches, calls);
    expect(state.notifications, isEmpty);
    expect(backend.channels.first.hasListener, isFalse);
  });

  scenario('disposal cancels polling and ignores pending inbox work', (
    tester,
  ) async {
    await signIn();
    final gate = Completer<List<BackendNotification>>();
    backend.fetch = () => gate.future;
    final refresh = state.refreshNotifications(silent: true);
    state.dispose();
    gate.complete([_row('late')]);
    await refresh;
    final calls = backend.fetches;
    await tester.pump(const Duration(seconds: 30));
    expect(backend.fetches, calls);
    expect(backend.channels.first.hasListener, isFalse);
    // tearDown disposes its own live state.
    state = _State();
  });
}
