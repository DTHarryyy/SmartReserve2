import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/backend/realtime_changes.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth implements GoTrueClient {
  @override
  User? currentUser = User(
    id: 'owner',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-10-11T00:00:00Z',
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Channel implements RealtimeChannel {
  late void Function(PostgresChangePayload) change;
  late void Function(RealtimeSubscribeStatus, Object?) status;
  PostgresChangeFilter? filter;
  String? table;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #onPostgresChanges) {
      change =
          invocation.namedArguments[#callback]
              as void Function(PostgresChangePayload);
      filter = invocation.namedArguments[#filter] as PostgresChangeFilter?;
      table = invocation.namedArguments[#table] as String?;
      return this;
    }
    if (invocation.memberName == #subscribe) {
      status =
          invocation.positionalArguments.first
              as void Function(RealtimeSubscribeStatus, Object?);
      return this;
    }
    return super.noSuchMethod(invocation);
  }
}

class _Client implements SupabaseClient {
  @override
  final _Auth auth = _Auth();
  final activeChannel = _Channel();
  int removed = 0;
  int channelsCreated = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #channel) {
      channelsCreated++;
      return activeChannel;
    }
    if (invocation.memberName == #removeChannel) {
      removed++;
      return Future<String>.value('ok');
    }
    return super.noSuchMethod(invocation);
  }
}

class _Service extends SupabaseService {
  _Service(super.client);
  int snapshots = 0;
  Future<List<BackendNotification>>? snapshotGate;

  @override
  Future<List<BackendNotification>> unreadNotifications() async {
    snapshots++;
    if (snapshotGate != null) return await snapshotGate!;
    return [
      BackendNotification(
        id: 'snapshot-$snapshots',
        kind: 'test',
        title: 'Snapshot',
        body: '',
        createdAt: DateTime.utc(2026, 10, 11),
      ),
    ];
  }
}

void main() {
  PostgresChangePayload event(String id, PostgresChangeEvent type) =>
      PostgresChangePayload(
        schema: 'public',
        table: 'app_notifications',
        commitTimestamp: DateTime.utc(2026, 10, 11),
        eventType: type,
        newRecord: type == PostgresChangeEvent.delete
            ? {}
            : {
                'id': id,
                'kind': 'test',
                'title': 'Live',
                'body': '',
                'created_at': '2026-10-11T00:00:00Z',
                'recipient_id': 'owner',
              },
        oldRecord: type == PostgresChangeEvent.delete ? {'id': id} : {},
        errors: null,
      );

  testWidgets('live rows bypass a pending startup snapshot and survive it', (
    tester,
  ) async {
    final client = _Client();
    final gate = Completer<List<BackendNotification>>();
    final service = _Service(client)..snapshotGate = gate.future;
    final deltas = <RowDelta<BackendNotification>>[];
    final subscription = service.notificationChanges().listen(deltas.add);
    client.activeChannel.status(RealtimeSubscribeStatus.subscribed, null);
    await tester.pump();
    client.activeChannel.change(event('live', PostgresChangeEvent.insert));
    client.activeChannel.change(event('deleted', PostgresChangeEvent.delete));
    await tester.pump();
    expect(deltas, hasLength(2));
    expect(deltas.first.upserts.single.id, 'live');
    expect(deltas.last.removedIds, {'deleted'});
    gate.complete([
      BackendNotification(
        id: 'deleted',
        kind: 'test',
        title: 'Old',
        body: '',
        createdAt: DateTime.utc(2026, 10, 11),
      ),
    ]);
    await tester.pump();
    expect(deltas.last.rows!.map((row) => row.id), ['live']);
    await subscription.cancel();
  });

  testWidgets('snapshot timeout keeps live delivery and reconnect recovery', (
    tester,
  ) async {
    final client = _Client();
    final gate = Completer<List<BackendNotification>>();
    final service = _Service(client)..snapshotGate = gate.future;
    final deltas = <RowDelta<BackendNotification>>[];
    final errors = <Object>[];
    final subscription = service.notificationChanges().listen(
      deltas.add,
      onError: errors.add,
    );
    client.activeChannel.status(RealtimeSubscribeStatus.subscribed, null);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(errors.single, isA<TimeoutException>());
    client.activeChannel.change(event('live', PostgresChangeEvent.insert));
    await tester.pump();
    expect(deltas.single.upserts.single.id, 'live');
    service.snapshotGate = null;
    client.activeChannel.status(RealtimeSubscribeStatus.subscribed, null);
    await tester.pump();
    expect(deltas.last.rows!.single.id, 'snapshot-2');
    gate.complete([]);
    await tester.pump();
    expect(deltas.last.rows!.single.id, 'snapshot-2');
    await subscription.cancel();
  });

  testWidgets('cancellation rejects a pending snapshot and late channel rows', (
    tester,
  ) async {
    final client = _Client();
    final gate = Completer<List<BackendNotification>>();
    final service = _Service(client)..snapshotGate = gate.future;
    final deltas = <RowDelta<BackendNotification>>[];
    final subscription = service.notificationChanges().listen(deltas.add);
    client.activeChannel.status(RealtimeSubscribeStatus.subscribed, null);
    await tester.pump();
    await subscription.cancel();
    client.activeChannel.change(event('late', PostgresChangeEvent.insert));
    gate.complete([]);
    await tester.pump();
    expect(deltas, isEmpty);
    expect(client.removed, 1);
  });

  testWidgets(
    'first join and reconnect fetch a snapshot scoped to the recipient',
    (tester) async {
      final client = _Client();
      final service = _Service(client);
      final deltas = <RowDelta<BackendNotification>>[];
      final subscription = service.notificationChanges().listen(deltas.add);
      expect(client.activeChannel.table, 'app_notifications');
      expect(client.activeChannel.filter?.column, 'recipient_id');
      expect(client.activeChannel.filter?.value, 'owner');

      client.activeChannel.status(RealtimeSubscribeStatus.subscribed, null);
      await tester.pump();
      expect(deltas.single.rows!.single.id, 'snapshot-1');
      client.activeChannel.status(
        RealtimeSubscribeStatus.channelError,
        StateError('offline'),
      );
      client.activeChannel.status(RealtimeSubscribeStatus.subscribed, null);
      await tester.pump();
      expect(deltas.last.rows!.single.id, 'snapshot-2');
      expect(service.snapshots, 2);
      await subscription.cancel();
      expect(client.removed, 1);
    },
  );

  testWidgets('row payload updates immediately without a debounce or fetch', (
    tester,
  ) async {
    final client = _Client();
    final service = _Service(client);
    final deltas = <RowDelta<BackendNotification>>[];
    final subscription = service.notificationChanges().listen(deltas.add);
    client.activeChannel.change(
      PostgresChangePayload(
        schema: 'public',
        table: 'app_notifications',
        commitTimestamp: DateTime.utc(2026, 10, 11),
        eventType: PostgresChangeEvent.insert,
        newRecord: {
          'id': 'live',
          'kind': 'test',
          'title': 'Live',
          'body': '',
          'created_at': '2026-10-11T00:00:00Z',
          'recipient_id': 'owner',
        },
        oldRecord: {},
        errors: null,
      ),
    );
    await tester.pump();
    expect(deltas.single.upserts.single.id, 'live');
    expect(service.snapshots, 0);
    await subscription.cancel();
  });

  test('signed-out notifications never create an unfiltered channel', () async {
    final client = _Client()..auth.currentUser = null;
    expect(await _Service(client).notificationChanges().toList(), isEmpty);
    expect(client.channelsCreated, 0);
  });
}
