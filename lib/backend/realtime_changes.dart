import 'dart:async';

/// One row-level change from a realtime channel, or a resync marker emitted
/// after the channel reconnects (changes may have been missed while offline).
class TableChange {
  const TableChange.row({
    required String this.id,
    required this.deleted,
    this.record = const {},
  });

  const TableChange.resync() : id = null, deleted = false, record = const {};

  final String? id;
  final bool deleted;
  final Map<String, dynamic> record;

  bool get isResync => id == null;
}

/// Batches [source] events and runs [process] on each batch, one batch at a
/// time. Events that arrive while [process] is running are merged into the
/// next batch, so a burst of N changes costs at most two runs instead of N.
Stream<R> coalesceChanges<E, R>(
  Stream<E> source,
  Future<R> Function(List<E> batch) process, {
  Duration debounce = const Duration(milliseconds: 250),
}) {
  late final StreamController<R> controller;
  final pending = <E>[];
  StreamSubscription<E>? subscription;
  Timer? timer;
  var running = false;

  Future<void> drain() async {
    if (running || pending.isEmpty || controller.isClosed) return;
    running = true;
    final batch = List<E>.of(pending);
    pending.clear();
    try {
      final result = await process(batch);
      if (!controller.isClosed) controller.add(result);
    } catch (error, stackTrace) {
      if (!controller.isClosed) controller.addError(error, stackTrace);
    } finally {
      running = false;
      if (pending.isNotEmpty && !controller.isClosed) {
        timer?.cancel();
        timer = Timer(debounce, drain);
      }
    }
  }

  controller = StreamController<R>(
    onListen: () {
      subscription = source.listen(
        (event) {
          pending.add(event);
          if (running) return;
          timer?.cancel();
          timer = Timer(debounce, drain);
        },
        onError: controller.addError,
        onDone: controller.close,
      );
    },
    onCancel: () async {
      timer?.cancel();
      pending.clear();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

/// Result of applying a batch of reservation or notification changes: either
/// a full replacement (after a resync) or per-row upserts and removals.
class RowDelta<T> {
  const RowDelta.replace(List<T> this.rows)
    : upserts = const [],
      removedIds = const {};

  const RowDelta.patch({required this.upserts, required this.removedIds})
    : rows = null;

  final List<T>? rows;
  final List<T> upserts;
  final Set<String> removedIds;

  bool get replacesAll => rows != null;
}

/// Merges [delta] into [current], keyed by [idOf]. Upserted rows that were not
/// present are placed first (newest-first lists); existing rows keep their slot.
List<T> applyRowDelta<T>(
  List<T> current,
  RowDelta<T> delta,
  String Function(T row) idOf,
) {
  if (delta.replacesAll) return List<T>.of(delta.rows!);
  final updates = {for (final row in delta.upserts) idOf(row): row};
  final merged = <T>[];
  final seen = <String>{};
  for (final row in current) {
    final id = idOf(row);
    if (delta.removedIds.contains(id)) continue;
    seen.add(id);
    merged.add(updates[id] ?? row);
  }
  final added = [
    for (final row in delta.upserts)
      if (!seen.contains(idOf(row)) && !delta.removedIds.contains(idOf(row)))
        row,
  ];
  return [...added, ...merged];
}
