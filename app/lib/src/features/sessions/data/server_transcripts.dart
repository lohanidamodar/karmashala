import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// What a server refused about a transcript, in its own words.
class ServerTranscriptException implements Exception {
  const ServerTranscriptException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The part of one session's transcript this client holds: [messages] are
/// the rows from index [from] on, of [total] the server's record holds.
class ServerTranscriptWindow {
  const ServerTranscriptWindow({
    required this.from,
    required this.total,
    required this.messages,
    this.absence,
    this.path,
  });

  final int from;
  final int total;
  final List<TranscriptMessage> messages;

  /// Why the server has no record to read (`TranscriptPage.absence`).
  final ChatViewEvidence? absence;

  /// The record's path on the server's machine, when located.
  final String? path;

  /// Rows before [from] the server holds and this client has not asked for.
  bool get hasOlder => from > 0 && absence == null;
}

/// **Sessions' transcripts, read by the server** (`sessions.transcript`,
/// Stage 0 step 6): the chat view, an imported session's history and a
/// subagent's turns, on this machine or any other.
///
/// Pull on notice. A session is watched while someone shows it
/// ([ServerTranscriptLease.watching]); the server tells this link
/// `transcriptChanged`, and the rows after this client's cursor are fetched
/// with the generation and revision it holds — new rows, `updates` for held
/// rows that moved, or `reset` with the tail when the record was replaced.
/// A new link watches nothing, so every watched session is watched again and
/// fetched from its cursor when the data client reconnects: nothing is
/// dropped and nothing is fetched twice. Older rows are asked for with
/// `before`, a page at a time, as the reader scrolls back.
class ServerTranscripts {
  ServerTranscripts(this._client) {
    _notices = _client.transcriptChanges.listen(_changed);
    _connection = _client.connectionChanges.listen((connection) {
      if (connection.state != DataLinkState.connected) return;
      for (final feed in [..._feeds.values]) {
        if (!feed.watched) continue;
        _send(SessionTranscriptWatch(feed.sessionId));
        _nudge(feed);
      }
    });
  }

  final DataClient _client;
  late final StreamSubscription<TranscriptChanged> _notices;
  late final StreamSubscription<DataConnection> _connection;

  /// Least recently opened first. Feeds nobody holds stay, up to [_kept],
  /// so a chat closed and reopened is fetched from its cursor, not again.
  final _feeds = <String, _Feed>{};
  static const int _kept = 16;

  /// Follows session [sessionId]'s transcript until [ServerTranscriptLease.close].
  ServerTranscriptLease open(String sessionId) {
    final feed = _feeds.remove(sessionId) ?? _Feed(sessionId);
    _feeds[sessionId] = feed;
    final lease = ServerTranscriptLease._(this, feed);
    feed.leases.add(lease);
    final window = feed.window;
    if (window != null) lease._emit(window);
    _trim();
    return lease;
  }

  /// The window [messages] was drawn from, when it is the one held for
  /// [sessionId] — the chat view reads [ServerTranscriptWindow.from] beside
  /// the rows it was handed.
  ServerTranscriptWindow? windowFor(
    String sessionId,
    List<TranscriptMessage>? messages,
  ) {
    final window = _feeds[sessionId]?.window;
    if (window == null || messages == null) return null;
    return identical(window.messages, messages) ? window : null;
  }

  /// Asks for the page before the rows held for [sessionId]. One at a time;
  /// a call while one is out is dropped.
  Future<void> loadOlder(String sessionId) {
    final feed = _feeds[sessionId];
    if (feed == null || feed.loadingOlder || !(feed.window?.hasOlder ?? false)) {
      return Future.value();
    }
    feed.loadingOlder = true;
    return _run(feed, () async {
      try {
        final generation = feed.generation;
        if (generation == null || generation.isEmpty || feed.from == 0) return;
        final page = await _read(
          SessionTranscriptRead(
            feed.sessionId,
            before: feed.from,
            generation: generation,
            revision: feed.revision,
          ),
        );
        if (page.reset || page.absence != null) {
          _replace(feed, page);
        } else {
          final end = page.from + page.messages.length;
          // A page that does not meet the rows held says nothing about them.
          if (end < feed.from) return;
          final overlap = end - feed.from;
          feed
            ..messages = [...page.messages, ...feed.messages.skip(overlap)]
            ..from = page.from
            ..total = page.total;
          // The revision stays: it names what the held rows are current to,
          // and these older ones are newer still.
        }
        _publish(feed);
      } on DataRefused catch (refusal) {
        _refused(feed, refusal);
      } finally {
        feed.loadingOlder = false;
      }
    });
  }

  /// One reading of [sessionId]'s record, without following it: what the
  /// chat-view probe asks.
  Future<TranscriptPage> peek(String sessionId) =>
      _read(SessionTranscriptRead(sessionId, limit: 1));

  /// A subagent's turns: the delegate at [path] of session [sessionId], read
  /// on the server a page at a time. Throws [DataRefused].
  Future<List<TranscriptMessage>> subagent(
    String sessionId,
    String path,
  ) async {
    final out = <TranscriptMessage>[];
    var after = 0;
    while (true) {
      final page = (await _client.send(
        SessionTranscriptSubagent(sessionId, path, after: after),
      )).value;
      out.addAll(page.messages);
      after = page.from + page.messages.length;
      if (!page.hasNewer || page.messages.isEmpty) return out;
    }
  }

  Future<void> dispose() async {
    await _notices.cancel();
    await _connection.cancel();
    for (final feed in [..._feeds.values]) {
      for (final lease in [...feed.leases]) {
        lease.close();
      }
    }
    _feeds.clear();
  }

  void _changed(TranscriptChanged change) {
    final feed = _feeds[change.sessionId];
    if (feed == null || !feed.watched) return;
    if (change.generation == feed.generation &&
        change.revision == feed.revision) {
      return;
    }
    _nudge(feed);
  }

  void _leaseWatching(_Feed feed) {
    final watched = feed.leases.any((lease) => lease._watching);
    if (watched == feed.watched) return;
    feed.watched = watched;
    if (watched) {
      _send(SessionTranscriptWatch(feed.sessionId));
      _nudge(feed);
    } else {
      _send(SessionTranscriptUnwatch(feed.sessionId));
    }
  }

  void _leaseClosed(_Feed feed, ServerTranscriptLease lease) {
    feed.leases.remove(lease);
    _leaseWatching(feed);
    _trim();
  }

  void _trim() {
    var spare = _feeds.values.where((feed) => feed.leases.isEmpty).length;
    for (final id in _feeds.keys.toList()) {
      if (spare <= _kept) return;
      if (_feeds[id]!.leases.isEmpty) {
        _feeds.remove(id);
        spare--;
      }
    }
  }

  /// Fire and forget: a watch lost with its link is asked again on the next.
  void _send(DataRequest<Object?> request) =>
      unawaited(_client.send(request).then<void>((_) {}, onError: (_) {}));

  /// Fetches from the cursor once whatever runs now is done; notices that
  /// arrive meanwhile are one fetch.
  void _nudge(_Feed feed) {
    if (feed.queued) return;
    feed.queued = true;
    unawaited(
      _run(feed, () async {
        feed.queued = false;
        if (!feed.watched && feed.window != null) return;
        await _fetchNewer(feed);
      }),
    );
  }

  Future<void> _run(_Feed feed, Future<void> Function() job) {
    final next = feed.lock.then((_) => job());
    feed.lock = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _fetchNewer(_Feed feed) async {
    final clock = Stopwatch()..start();
    final first = feed.window == null;
    try {
      while (true) {
        final generation = feed.generation;
        final holding = generation != null && generation.isNotEmpty;
        final page = await _read(
          holding
              ? SessionTranscriptRead(
                  feed.sessionId,
                  after: feed.from + feed.messages.length,
                  generation: generation,
                  revision: feed.revision,
                )
              : SessionTranscriptRead(feed.sessionId),
        );
        if (!holding || page.reset || page.absence != null) {
          _replace(feed, page);
        } else if (!_merge(feed, page)) {
          // Rows that do not meet the ones held: start over from the tail.
          feed.generation = null;
          continue;
        }
        _publish(feed);
        if (kDebugMode) {
          debugPrint(
            '[transcripts] ${feed.sessionId}: '
            '${first ? 'first page in ${clock.elapsedMilliseconds} ms, ' : ''}'
            '${page.messages.length} rows, ${page.updates.length} updates'
            '${page.reset ? ', reset' : ''}, ${_bytes(page)} B',
          );
        }
        if (page.absence != null || !page.hasNewer) return;
      }
    } on DataRefused catch (refusal) {
      _refused(feed, refusal);
    }
  }

  /// What a page costs on the wire — a debug measure (spec Stage 0).
  static int _bytes(TranscriptPage page) =>
      utf8.encode(jsonEncode(page.toJson())).length;

  void _replace(_Feed feed, TranscriptPage page) {
    feed
      ..generation = page.generation
      ..revision = page.revision
      ..from = page.from
      ..total = page.total
      ..messages = page.messages
      ..absence = page.absence
      ..path = page.path;
  }

  /// False when [page] does not continue the rows held.
  bool _merge(_Feed feed, TranscriptPage page) {
    final at = page.from - feed.from;
    if (at < 0 || at > feed.messages.length) return false;
    final rows = [...feed.messages.take(at)];
    for (final update in page.updates) {
      final index = update.index - feed.from;
      // A row before the window is fetched current when scrolled back to.
      if (index >= 0 && index < rows.length) rows[index] = update.message;
    }
    rows.addAll(page.messages);
    feed
      ..messages = rows
      ..revision = page.revision
      ..total = page.total
      ..absence = null
      ..path = page.path ?? feed.path;
    return true;
  }

  void _publish(_Feed feed) {
    final window = ServerTranscriptWindow(
      from: feed.from,
      total: feed.total,
      messages: List.unmodifiable(feed.messages),
      absence: feed.absence,
      path: feed.path,
    );
    feed.window = window;
    for (final lease in [...feed.leases]) {
      lease._emit(window);
    }
  }

  /// A server away is fetched again when it is back; any other refusal is
  /// the server's answer, shown in its words.
  void _refused(_Feed feed, DataRefused refusal) {
    if (refusal.code == DataRefusalCode.unavailable) return;
    final error = ServerTranscriptException(refusal.message);
    for (final lease in [...feed.leases]) {
      lease._fail(error);
    }
  }

  Future<TranscriptPage> _read(SessionTranscriptRead request) async =>
      (await _client.send(request)).value;
}

/// One reader of one session's transcript: the chat view, an imported
/// session's history. The server is told to watch while any lease is
/// [watching]; the rows held are kept when none is.
class ServerTranscriptLease {
  ServerTranscriptLease._(this._owner, this._feed);

  final ServerTranscripts _owner;
  final _Feed _feed;
  final _windows = StreamController<ServerTranscriptWindow>();
  bool _watching = false;
  bool _closed = false;

  /// Each window as it changes; the one held already, first.
  Stream<ServerTranscriptWindow> get windows => _windows.stream;

  set watching(bool value) {
    if (_closed || value == _watching) return;
    _watching = value;
    _owner._leaseWatching(_feed);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _watching = false;
    unawaited(_windows.close());
    _owner._leaseClosed(_feed, this);
  }

  void _emit(ServerTranscriptWindow window) {
    if (!_closed) _windows.add(window);
  }

  void _fail(Object error) {
    if (!_closed) _windows.addError(error);
  }
}

class _Feed {
  _Feed(this.sessionId);

  final String sessionId;
  final leases = <ServerTranscriptLease>{};
  bool watched = false;

  /// Null until a page is held; empty while the server says why there is
  /// none ([absence]).
  String? generation;
  int revision = 0;
  int from = 0;
  int total = 0;
  List<TranscriptMessage> messages = const [];
  ChatViewEvidence? absence;
  String? path;
  ServerTranscriptWindow? window;

  Future<void> lock = Future.value();
  bool queued = false;
  bool loadingOlder = false;
}

final serverTranscriptsProvider = Provider<ServerTranscripts>((ref) {
  final transcripts = ServerTranscripts(ref.watch(dataClientProvider));
  ref.onDispose(transcripts.dispose);
  return transcripts;
});
