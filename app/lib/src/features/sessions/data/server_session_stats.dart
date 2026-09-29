import 'dart:async';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// **Sessions' counts, read by the server** (`sessions.stats`, Stage 0 step
/// 9), batched and held.
///
/// Every session asked for within one turn of the event loop goes in one
/// request, so a list of rows that each ask is one round trip. A reading is
/// held for [fresh], and dropped sooner when the server says the session's
/// transcript moved (`transcriptChanged`, told for the sessions a chat
/// watches) or the link is new, since notices sent meanwhile were lost.
class ServerSessionStats {
  ServerSessionStats(
    this._client, {
    this.fresh = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _notices = _client.transcriptChanges.listen(
      (change) => _drop(change.sessionId),
    );
    _connection = _client.connectionChanges.listen((connection) {
      if (connection.state == DataLinkState.connected) forget();
    });
  }

  final DataClient _client;
  final Duration fresh;
  final DateTime Function() _now;
  late final StreamSubscription<TranscriptChanged> _notices;
  late final StreamSubscription<DataConnection> _connection;

  final _held =
      <String, ({DateTime at, SessionStatsReading reading, bool lifetime})>{};

  /// Bumped per drop, so a reading asked for before a drop is not held
  /// after it.
  final _dropped = <String, int>{};
  int _epoch = 0;

  final _waiting = <String, _Ask>{};
  bool _flushQueued = false;

  /// Session [sessionId]'s counts, and with [lifetime] its agent's lifetime
  /// totals. [current] skips a held reading. Throws [DataRefused]; an older
  /// server refuses the kind as `invalid`.
  Future<SessionStatsReading> read(
    String sessionId, {
    bool lifetime = false,
    bool current = false,
  }) {
    if (!current) {
      final held = _held[sessionId];
      if (held != null &&
          (held.lifetime || !lifetime) &&
          _now().difference(held.at) < fresh) {
        return Future.value(held.reading);
      }
    }
    final ask = _waiting.putIfAbsent(sessionId, _Ask.new);
    ask.lifetime |= lifetime;
    if (!_flushQueued) {
      _flushQueued = true;
      Timer.run(_flush);
    }
    return ask.done.future;
  }

  /// [read] for each of [sessionIds], held readings first: one request for
  /// the rest, or one per [kSessionStatsBatchMax].
  Future<Map<String, SessionStatsReading>> readAll(
    Iterable<String> sessionIds,
  ) async {
    final ids = sessionIds.toSet().toList(growable: false);
    final readings = await Future.wait([for (final id in ids) read(id)]);
    return {for (var i = 0; i < ids.length; i++) ids[i]: readings[i]};
  }

  /// Drops every held reading: a person asked to count again.
  void forget() {
    _held.clear();
    _epoch++;
  }

  Future<void> dispose() async {
    await _notices.cancel();
    await _connection.cancel();
    final waiting = [..._waiting.values];
    _waiting.clear();
    for (final ask in waiting) {
      ask.done.completeError(
        const DataRefused.unavailable('the data client closed'),
      );
    }
  }

  void _drop(String sessionId) {
    _held.remove(sessionId);
    _dropped[sessionId] = (_dropped[sessionId] ?? 0) + 1;
  }

  Future<void> _flush() async {
    _flushQueued = false;
    final asks = Map.of(_waiting);
    _waiting.clear();
    final withLifetime = [
      for (final MapEntry(:key, :value) in asks.entries)
        if (value.lifetime) key,
    ];
    final plain = [
      for (final MapEntry(:key, :value) in asks.entries)
        if (!value.lifetime) key,
    ];
    await Future.wait([
      for (var i = 0; i < withLifetime.length; i += kSessionStatsBatchMax)
        _send(asks, withLifetime.skip(i).take(kSessionStatsBatchMax), true),
      for (var i = 0; i < plain.length; i += kSessionStatsBatchMax)
        _send(asks, plain.skip(i).take(kSessionStatsBatchMax), false),
    ]);
  }

  Future<void> _send(
    Map<String, _Ask> asks,
    Iterable<String> chunk,
    bool lifetime,
  ) async {
    final ids = chunk.toList(growable: false);
    final epoch = _epoch;
    final dropped = {for (final id in ids) id: _dropped[id] ?? 0};
    try {
      final batch = (await _client.send(
        SessionStatsRead(ids, lifetime: lifetime),
      )).value;
      final at = _now();
      for (final id in ids) {
        final reading =
            batch.sessions[id] ??
            const SessionStatsReading(gap: SessionStatsGap.recordNotFound);
        if (epoch == _epoch && (_dropped[id] ?? 0) == dropped[id]) {
          _held[id] = (at: at, reading: reading, lifetime: lifetime);
        }
        asks[id]!.done.complete(reading);
      }
    } on Object catch (error, stack) {
      for (final id in ids) {
        asks[id]!.done.completeError(error, stack);
      }
    }
  }
}

class _Ask {
  final done = Completer<SessionStatsReading>();
  bool lifetime = false;
}

final serverSessionStatsProvider = Provider<ServerSessionStats>((ref) {
  final stats = ServerSessionStats(ref.watch(dataClientProvider));
  ref.onDispose(stats.dispose);
  return stats;
});
