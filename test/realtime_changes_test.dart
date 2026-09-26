import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/backend/realtime_changes.dart';

void main() {
  group('coalesceChanges', () {
    test('a burst of events costs at most two runs', () async {
      final source = StreamController<int>();
      final batches = <List<int>>[];
      final gate = Completer<void>();
      final results = coalesceChanges<int, int>(source.stream, (batch) async {
        batches.add(batch);
        if (batches.length == 1) await gate.future;
        return batch.length;
      }, debounce: const Duration(milliseconds: 10));
      final received = <int>[];
      final subscription = results.listen(received.add);

      for (var i = 0; i < 5; i++) {
        source.add(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // Arrives while the first batch is still running.
      for (var i = 5; i < 20; i++) {
        source.add(i);
      }
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(batches, hasLength(2));
      expect(batches[0], [0, 1, 2, 3, 4]);
      expect(batches[1], hasLength(15));
      expect(received, [5, 15]);
      await subscription.cancel();
      await source.close();
    });

    test('errors from a run are forwarded and later runs continue', () async {
      final source = StreamController<int>();
      var runs = 0;
      final results = coalesceChanges<int, int>(source.stream, (batch) async {
        runs++;
        if (runs == 1) throw StateError('offline');
        return runs;
      }, debounce: const Duration(milliseconds: 5));
      final errors = <Object>[];
      final values = <int>[];
      final subscription = results.listen(values.add, onError: errors.add);

      source.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.add(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(errors.single, isA<StateError>());
      expect(values, [2]);
      await subscription.cancel();
      await source.close();
    });
  });

  group('applyRowDelta', () {
    String id(String row) => row.split(':').first;

    test('replaces rows in place, removes deleted and prepends new', () {
      final merged = applyRowDelta(
        ['a:1', 'b:1', 'c:1'],
        const RowDelta.patch(upserts: ['d:1', 'b:2'], removedIds: {'c'}),
        id,
      );
      expect(merged, ['d:1', 'a:1', 'b:2']);
    });

    test('a replace delta swaps the whole list', () {
      final merged = applyRowDelta(
        ['a:1'],
        const RowDelta.replace(['x:1', 'y:1']),
        id,
      );
      expect(merged, ['x:1', 'y:1']);
    });
  });
}
