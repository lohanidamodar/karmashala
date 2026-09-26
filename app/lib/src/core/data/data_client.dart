import 'dart:async';
import 'dart:math' as math;

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_store/database.dart';

import 'in_process_data_endpoint.dart';
import 'keyed_replica.dart';

/// The domains this app reads through the server.
enum DataDomain { notes, todos, preferences }

/// How this app reaches the server's data now.
enum DataLinkState {
  /// Over the server's socket.
  connected,

  /// The server went away; writes wait for it to come back.
  reconnecting,

  /// No server: the temporary in-process fallback ([InProcessDataEndpoint]).
  inProcess,
}

/// [state], and in words why when it is not [DataLinkState.connected].
class DataConnection {
  const DataConnection(this.state, [this.reason]);

  final DataLinkState state;
  final String? reason;

  @override
  String toString() => reason == null ? state.name : '${state.name}: $reason';
}

/// This app's client of the server's data: one link, a copy of each domain
/// the server keeps up to date ([notes], [todos], [preferences]), and the
/// writes, which land in the copy at once and at the server after. Reading
/// never waits: the copies are primed before the first frame.
class DataClient {
  DataClient._(
    this._dial,
    this._endpoint,
    this._connection, {
    AppLogger? logger,
  }) : _log = logger ?? AppLogger.named('data');

  /// **Temporary fallback** — the server's handlers in this process, over
  /// [database]. Used under `flutter test` and where no server could be
  /// started; [reason] says which. Answers synchronously.
  factory DataClient.inProcess(
    AppDatabase database, {
    String reason = 'no Karmashala server runs here',
    DateTime Function()? clock,
    AppLogger? logger,
  }) => DataClient.over(
    InProcessDataEndpoint(database, clock: clock),
    reason: reason,
    logger: logger,
  );

  /// The fallback over [endpoint] — for a test, two clients of one service.
  factory DataClient.over(
    InProcessDataEndpoint endpoint, {
    String reason = 'no Karmashala server runs here',
    AppLogger? logger,
  }) {
    final client = DataClient._(
      null,
      endpoint,
      DataConnection(DataLinkState.inProcess, reason),
      logger: logger,
    );
    client._listen(endpoint);
    endpoint.sendNow(const DataSubscribe());
    return client;
  }

  /// Dials the server with [dial] and primes every copy. Throws
  /// [DataRefused] when the first dial finds no server — the caller decides
  /// what that means. After it, a lost server is redialled for as long as
  /// the client lives, and writes wait up to [waitForServer] for it.
  static Future<DataClient> connect(
    Future<DataEndpoint?> Function() dial, {
    Duration waitForServer = const Duration(seconds: 20),
    AppLogger? logger,
  }) async {
    final client = DataClient._(
      dial,
      null,
      const DataConnection(DataLinkState.reconnecting, 'not connected yet'),
      logger: logger,
    ).._waitForServer = waitForServer;
    final endpoint = await dial();
    if (endpoint == null) {
      throw const DataRefused.unavailable(
        'the Karmashala server is not running',
      );
    }
    try {
      await client._attach(endpoint);
    } on Object {
      await client.close();
      await endpoint.close();
      rethrow;
    }
    return client;
  }

  final Future<DataEndpoint?> Function()? _dial;
  final AppLogger _log;
  DataEndpoint? _endpoint;
  DataConnection _connection;
  Duration _waitForServer = const Duration(seconds: 20);
  Completer<void>? _ready;
  StreamSubscription<DataChanges>? _changesSubscription;
  final _connectionChanges = StreamController<DataConnection>.broadcast();
  var _closed = false;

  final notes = KeyedReplica<Note>();
  final todos = KeyedReplica<Todo>();
  final preferences = KeyedReplica<String>();

  DataConnection get connection => _connection;

  Stream<DataConnection> get connectionChanges => _connectionChanges.stream;

  /// Primes [domain]'s copy now when this client can answer synchronously
  /// (the fallback) and it has not been; a server's copies are primed when
  /// it attaches.
  void ensurePrimed(DataDomain domain) {
    final endpoint = _endpoint;
    if (endpoint is! InProcessDataEndpoint || _replica(domain).isPrimed) {
      return;
    }
    _prime(domain, endpoint);
  }

  void _prime(DataDomain domain, InProcessDataEndpoint endpoint) {
    switch (domain) {
      case DataDomain.notes:
        _replaceNotes(endpoint.sendNow(const NotesList()));
      case DataDomain.todos:
        _replaceTodos(endpoint.sendNow(const TodosList()));
      case DataDomain.preferences:
        _replacePreferences(endpoint.sendNow(const PreferencesGet()));
    }
  }

  /// Sends [request] and applies its answer with [apply] — synchronously,
  /// before this returns, on the fallback. A refusal re-reads [domain] (the
  /// local write it undoes is gone with it) and is rethrown.
  Future<R> write<R>(
    DataRequest<R> request, {
    required DataDomain domain,
    required void Function(R value, int revision) apply,
  }) {
    final endpoint = _endpoint;
    if (endpoint is InProcessDataEndpoint) {
      try {
        final reply = endpoint.sendNow(request);
        apply(reply.value, reply.revision);
        return Future.value(reply.value);
      } on DataRefused catch (refusal) {
        _prime(domain, endpoint);
        return Future.error(refusal);
      }
    }
    final write = _writeToServer(request, domain, apply);
    _inFlight.add(write);
    unawaited(
      write
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _inFlight.remove(write)),
    );
    return write;
  }

  /// Writes sent and not yet answered, which [close] waits for: a setting
  /// changed as the app quits must still reach the server.
  final _inFlight = <Future<Object?>>{};

  Future<R> _writeToServer<R>(
    DataRequest<R> request,
    DataDomain domain,
    void Function(R value, int revision) apply,
  ) async {
    try {
      final reply = await send(request);
      apply(reply.value, reply.revision);
      return reply.value;
    } on DataRefused catch (refusal) {
      // A server that went away mid-write is re-read whole when it is back.
      if (refusal.code != DataRefusalCode.unavailable) {
        unawaited(resync(domain).catchError((Object _) {}));
      }
      rethrow;
    }
  }

  /// [request] answered by the server, waiting up to the bound for one that
  /// is reconnecting. Throws [DataRefused].
  Future<DataReply<R>> send<R>(DataRequest<R> request) async {
    if (_closed) {
      throw const DataRefused.unavailable('the data client is closed');
    }
    var endpoint = _endpoint;
    if (endpoint == null) {
      final ready = _ready ??= Completer<void>();
      try {
        await ready.future.timeout(_waitForServer);
      } on TimeoutException {
        throw DataRefused.unavailable(
          'the Karmashala server is not running'
          '${_connection.reason == null ? '' : ' (${_connection.reason})'}',
        );
      }
      endpoint = _endpoint;
      if (endpoint == null) {
        throw const DataRefused.unavailable('the Karmashala server went away');
      }
    }
    return endpoint.send(request);
  }

  /// Reads [domain] again, whole — after a write this app made to its rows
  /// some other way (a project deleted clears their filing).
  Future<void> resync(DataDomain domain) async {
    final endpoint = _endpoint;
    if (endpoint is InProcessDataEndpoint) {
      _prime(domain, endpoint);
      return;
    }
    switch (domain) {
      case DataDomain.notes:
        _replaceNotes(await send(const NotesList()));
      case DataDomain.todos:
        _replaceTodos(await send(const TodosList()));
      case DataDomain.preferences:
        _replacePreferences(await send(const PreferencesGet()));
    }
  }

  KeyedReplica<Object> _replica(DataDomain domain) => switch (domain) {
    DataDomain.notes => notes,
    DataDomain.todos => todos,
    DataDomain.preferences => preferences,
  };

  void _replaceNotes(DataReply<List<Note>> reply) => notes.replaceAll({
    for (final note in reply.value) note.id: note,
  }, reply.revision);

  void _replaceTodos(DataReply<List<Todo>> reply) => todos.replaceAll({
    for (final todo in reply.value) todo.id: todo,
  }, reply.revision);

  void _replacePreferences(DataReply<Map<String, String>> reply) =>
      preferences.replaceAll(reply.value, reply.revision);

  void _listen(DataEndpoint endpoint) {
    unawaited(_changesSubscription?.cancel());
    _changesSubscription = endpoint.changes.listen(_onChanges);
  }

  void _onChanges(DataChanges batch) {
    for (final change in batch.changes) {
      switch (change) {
        case NoteChanged(:final note):
          notes.applyAt(note.id, note, batch.revision);
        case NoteRemoved(:final id):
          notes.applyAt(id, null, batch.revision);
        case TodoChanged(:final todo):
          todos.applyAt(todo.id, todo, batch.revision);
        case TodoRemoved(:final id):
          todos.applyAt(id, null, batch.revision);
        case PreferenceChanged(:final key, :final value):
          preferences.applyAt(key, value, batch.revision);
      }
    }
  }

  Future<void> _attach(DataEndpoint endpoint) async {
    _listen(endpoint);
    await endpoint.send(const DataSubscribe());
    _endpoint = endpoint;
    unawaited(endpoint.done.then((_) => _lost(endpoint)));
    _setConnection(const DataConnection(DataLinkState.connected));
    // Writes that waited go first, in the order they were made; the
    // snapshot after them then includes them.
    _ready?.complete();
    _ready = null;
    await Future<void>.delayed(Duration.zero);
    final snapshot = await Future.wait([
      endpoint.send(const NotesList()),
      endpoint.send(const TodosList()),
      endpoint.send(const PreferencesGet()),
    ]);
    _replaceNotes(snapshot[0] as DataReply<List<Note>>);
    _replaceTodos(snapshot[1] as DataReply<List<Todo>>);
    _replacePreferences(snapshot[2] as DataReply<Map<String, String>>);
  }

  void _lost(DataEndpoint endpoint) {
    if (_closed || !identical(endpoint, _endpoint)) return;
    _endpoint = null;
    _setConnection(
      const DataConnection(
        DataLinkState.reconnecting,
        'the link to the Karmashala server closed',
      ),
    );
    if (_redialing) return;
    _log.warning('The link to the Karmashala server closed; redialling.');
    unawaited(_redial());
  }

  var _redialing = false;

  static const _backoff = [
    Duration(milliseconds: 250),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  Future<void> _redial() async {
    final dial = _dial;
    if (dial == null) return;
    _redialing = true;
    try {
      await _redialLoop(dial);
    } finally {
      _redialing = false;
    }
  }

  Future<void> _redialLoop(Future<DataEndpoint?> Function() dial) async {
    for (var attempt = 0; !_closed; attempt++) {
      await Future<void>.delayed(
        _backoff[math.min(attempt, _backoff.length - 1)],
      );
      if (_closed) return;
      DataEndpoint? endpoint;
      try {
        endpoint = await dial();
        if (endpoint == null) continue;
        await _attach(endpoint);
        _log.info('Reconnected to the Karmashala server.');
        return;
      } on Object catch (error) {
        if (identical(_endpoint, endpoint)) _endpoint = null;
        await endpoint?.close();
        _setConnection(DataConnection(DataLinkState.reconnecting, '$error'));
      }
    }
  }

  void _setConnection(DataConnection connection) {
    _connection = connection;
    if (!_connectionChanges.isClosed) _connectionChanges.add(connection);
  }

  /// Closes the link once the writes in flight are answered, or after
  /// [flushWithin].
  Future<void> close({
    Duration flushWithin = const Duration(seconds: 2),
  }) async {
    if (_closed) return;
    if (_inFlight.isNotEmpty) {
      await Future.wait([
        for (final write in _inFlight)
          write.then<void>((_) {}, onError: (Object _) {}),
      ]).timeout(flushWithin, onTimeout: () => const []);
    }
    _closed = true;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        const DataRefused.unavailable('the data client is closed'),
      );
      unawaited(ready.future.catchError((Object _) {}));
    }
    await _changesSubscription?.cancel();
    await _endpoint?.close();
    _endpoint = null;
    await _connectionChanges.close();
    await notes.dispose();
    await todos.dispose();
    await preferences.dispose();
  }
}
