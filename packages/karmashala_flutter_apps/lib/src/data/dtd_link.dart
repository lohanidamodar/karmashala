import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/dtd_instance.dart';

/// One JSON-RPC channel to a tooling daemon; an interface rather than a socket
/// so tests answer in Dart.
abstract interface class DtdChannel {
  Stream<String> get messages;
  void send(String message);
  Future<void> close();
}

/// Opens a channel to a daemon at [wsUri].
typedef DtdChannelOpener = Future<DtdChannel> Function(Uri wsUri);

/// How long a daemon has to answer before we give up on it.
const Duration kDtdTimeout = Duration(seconds: 5);

/// A live conversation with one tooling daemon. The socket is held open
/// because an IDE's daemon outlives its runs: only the event says a new app
/// started.
class DtdLink {
  DtdLink._(this._channel);

  final DtdChannel _channel;
  final _pending = <String, Completer<Map<String, Object?>>>{};
  final _registered = StreamController<DtdApp>.broadcast();
  StreamSubscription<String>? _messages;
  var _nextId = 0;
  var _closed = false;

  /// Apps the daemon registered after we started listening.
  Stream<DtdApp> get registered => _registered.stream;

  /// Connects and subscribes to the daemon's app events.
  static Future<DtdLink> open(
    Uri wsUri, {
    required DtdChannelOpener open,
  }) async {
    final link = DtdLink._(await open(wsUri));
    link._messages = link._channel.messages.listen(
      link._onMessage,
      onError: (Object _) => link._finish(),
      onDone: link._finish,
      cancelOnError: false,
    );
    // Subscribed before anything is asked, so an app that starts during the
    // first read is an event rather than a miss. Best-effort: a daemon too old
    // for the stream can still be asked.
    try {
      await link._call('streamListen', <String, Object?>{
        'streamId': 'ConnectedApp',
      });
    } on DtdUnavailable {
      // `apps()` still works, and a daemon that has gone away fails there too.
    }
    return link;
  }

  /// Every app the daemon knows about right now.
  Future<List<DtdApp>> apps() async {
    final result = await _call('ConnectedApp.getVmServices', const {});
    return vmServicesInDtdReply(jsonEncode(result));
  }

  Future<void> dispose() async {
    _finish();
    await _messages?.cancel();
    await _channel.close();
  }

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> params,
  ) async {
    if (_closed) throw const DtdUnavailable('the daemon closed the connection');
    final id = '${_nextId++}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _channel.send(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    try {
      return await completer.future.timeout(kDtdTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw const DtdUnavailable('the daemon did not answer');
    }
  }

  void _onMessage(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;

    final id = decoded['id'];
    if (id is String) {
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = decoded['error'];
      if (error != null) {
        completer.completeError(DtdUnavailable('$error'));
        return;
      }
      final result = decoded['result'];
      completer.complete(
        result is Map<String, Object?> ? result : const <String, Object?>{},
      );
      return;
    }

    if (decoded['method'] != 'streamNotify') return;
    final params = decoded['params'];
    if (params is! Map) return;
    if (params['eventKind'] != 'VmServiceRegistered') return;
    final data = params['eventData'];
    if (data is! Map<String, Object?>) return;
    final apps = vmServicesInDtdReply(
      jsonEncode(<String, Object?>{
        'vmServices': <Object?>[data],
      }),
    );
    for (final app in apps) {
      if (!_registered.isClosed) _registered.add(app);
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const DtdUnavailable('the daemon closed the connection'),
        );
      }
    }
    _pending.clear();
    unawaited(_registered.close());
  }
}

/// A daemon that could not be reached or would not answer. A pid file outlives
/// a crash, so the caller drops the daemon rather than reporting a failure.
class DtdUnavailable implements Exception {
  const DtdUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'DtdUnavailable: $reason';
}

/// The real channel: a WebSocket to the daemon's own address.
Future<DtdChannel> openDtdOverWebSocket(Uri wsUri) async {
  final socket = await WebSocket.connect(wsUri.toString()).timeout(kDtdTimeout);
  return _SocketChannel(socket);
}

class _SocketChannel implements DtdChannel {
  _SocketChannel(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get messages => _socket.map(
    (event) => event is String ? event : utf8.decode(event as List<int>),
  );

  @override
  void send(String message) => _socket.add(message);

  @override
  Future<void> close() => _socket.close();
}
