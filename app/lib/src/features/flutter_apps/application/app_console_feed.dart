import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import '../data/flutter_data.dart';
import 'attached_apps.dart';

/// One app's console as this client follows it: the server's backlog, then
/// each batch as it lands, in a bounded buffer of its own. [missed] counts
/// what the server dropped because this client fell behind.
class AppConsoleFeed {
  AppConsoleFeed(Stream<DataStreamItems> source) {
    _subscription = source.listen(
      _onBatch,
      onError: (Object error) => ended = '$error',
      onDone: () => ended ??= 'the stream closed',
    );
  }

  final _buffer = AppLogBuffer();
  final _ticks = StreamController<int>.broadcast(sync: true);
  late final StreamSubscription<DataStreamItems> _subscription;

  /// Lines the server dropped before sending, because this client was slow.
  int missed = 0;

  /// Why the stream ended, or null while it runs.
  String? ended;

  /// Console lines received so far; the sequence number of the next one.
  int get consoleAppended => _buffer.appended;

  /// A tick per batch, so a view repaints without holding the lines.
  Stream<int> get ticks => _ticks.stream;

  AppLogFilterResult filterConsole(
    AppLogFilterCache cache,
    AppLogQuery query, {
    int hideBefore = 0,
  }) => cache.update(_buffer, query, hideBefore: hideBefore);

  void _onBatch(DataStreamItems batch) {
    missed += batch.dropped;
    for (final item in batch.items) {
      if (item is! Map) continue;
      try {
        _buffer.add(appLogRecordFromJson(item.cast<String, Object?>()));
      } on FormatException {
        // A line this build cannot read is skipped, not fatal.
      }
    }
    if (batch.ended != null) ended = batch.ended;
    if (!_ticks.isClosed) _ticks.add(_buffer.appended);
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await _ticks.close();
  }
}

/// App [appId]'s console while something shows it; a re-attach (the
/// registry moving) opens a fresh one.
final appConsoleFeedProvider = Provider.autoDispose
    .family<AppConsoleFeed?, String>((ref, appId) {
      final (attached, _) = ref.watch(
        attachedAppsProvider.select((registry) {
          final app = registry.byId(appId);
          return (app?.isAttached ?? false, app?.observedAt);
        }),
      );
      if (!attached) return null;
      final feed = AppConsoleFeed(ref.read(flutterDataProvider).console(appId));
      ref.onDispose(feed.dispose);
      return feed;
    });
