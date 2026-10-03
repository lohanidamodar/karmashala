import 'dart:async';
import 'dart:convert';

import '../errors.dart';
import '../json.dart';
import '../vocabulary.dart';
import 'peer_messages.dart';

/// A JSON-RPC 2.0 peer over newline-delimited JSON, as ACP runs it on an
/// agent's stdio. Symmetric: either side may call, notify, or answer.
///
/// Spec: https://agentclientprotocol.com/protocol/v1/overview
class AcpPeer {
  AcpPeer(Stream<List<int>> input, StreamSink<List<int>> output)
    : _output = output {
    _subscription = input
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine, onError: _onInputError, onDone: _onInputDone);
  }

  final StreamSink<List<int>> _output;
  late final StreamSubscription<String> _subscription;

  final _requests = StreamController<AcpIncomingRequest>();
  final _notifications = StreamController<AcpNotification>();
  final _malformed = StreamController<AcpMalformedLine>.broadcast();
  final _pending = <Object, _PendingCall>{};
  final _incoming = <Object, AcpIncomingRequest>{};
  final _done = Completer<void>();
  var _nextId = 1;
  var _closed = false;

  /// Requests from the other side; buffered until listened to, so none is
  /// lost while a facade attaches.
  Stream<AcpIncomingRequest> get requests => _requests.stream;

  Stream<AcpNotification> get notifications => _notifications.stream;

  /// Lines that were not JSON-RPC. Broadcast: unheard, they are dropped.
  Stream<AcpMalformedLine> get malformed => _malformed.stream;

  bool get isClosed => _closed;

  /// Completes when [close] ran or the input ended, whichever came first.
  Future<void> get done => _done.future;

  /// Sends a request and completes with its `result`; an `error` answer
  /// becomes an [AcpRpcError], and closing before the answer an
  /// [AcpPeerClosed].
  Future<Object?> call(String method, Object? params) {
    if (_closed) return Future.error(AcpPeerClosed(method));
    final id = _nextId++;
    final pending = _PendingCall(method);
    _pending[id] = pending;
    _send(
      withoutNulls({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return pending.completer.future;
  }

  void notify(String method, Object? params) {
    if (_closed) return;
    _send(withoutNulls({'jsonrpc': '2.0', 'method': method, 'params': params}));
  }

  /// Stops reading, fails every unanswered call, and closes the output.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _failAllPending();
    // A controller nobody listened to reports done only once drained, and a
    // sink whose reader is gone may refuse: neither is worth waiting on.
    unawaited(_requests.close());
    unawaited(_notifications.close());
    unawaited(_malformed.close());
    unawaited(_output.close().then((_) {}, onError: (Object _) {}));
    if (!_done.isCompleted) _done.complete();
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      _malformed.add(AcpMalformedLine(line, 'not JSON: ${e.message}'));
      return;
    }
    final message = asJsonMap(decoded);
    if (message == null) {
      _malformed.add(AcpMalformedLine(line, 'not a JSON object'));
      return;
    }
    final method = message['method'];
    final hasId = message['id'] != null;
    if (method is String) {
      if (hasId) {
        _onRequest(message['id']!, method, message['params']);
      } else {
        _onNotification(method, message['params']);
      }
    } else if (hasId) {
      _onResponse(message['id']!, message);
    } else {
      _malformed.add(
        AcpMalformedLine(line, 'neither request, notification nor response'),
      );
    }
  }

  void _onRequest(Object id, String method, Object? params) {
    if (method == AcpMethods.cancelRequest) {
      _cancelIncoming(params);
      _reply(id, const <String, Object?>{});
      return;
    }
    final request = AcpIncomingRequest(
      id: id,
      method: method,
      params: params,
      onRespond: (result) {
        _incoming.remove(id);
        _reply(id, result);
      },
      onFail: (code, message, data) {
        _incoming.remove(id);
        _replyError(id, code, message, data);
      },
    );
    _incoming[id] = request;
    _requests.add(request);
  }

  void _onNotification(String method, Object? params) {
    if (method == AcpMethods.cancelRequest) {
      _cancelIncoming(params);
      return;
    }
    _notifications.add(AcpNotification(method, params));
  }

  /// The other side withdrew a request it made: answer -32800 now, and let
  /// the handler see it was cancelled so it can stop.
  void _cancelIncoming(Object? params) {
    final requestId = asJsonMap(params)?['requestId'];
    final request = requestId == null ? null : _incoming[requestId];
    if (request == null) return;
    request.markCancelled();
    request.fail(JsonRpcErrorCodes.requestCancelled, 'Request cancelled');
  }

  void _onResponse(Object id, JsonMap message) {
    final pending = _pending.remove(id);
    if (pending == null) {
      _malformed.add(
        AcpMalformedLine(jsonEncode(message), 'response to unknown id $id'),
      );
      return;
    }
    final error = message.object('error');
    if (error != null) {
      pending.completer.completeError(AcpRpcError.fromJson(error));
    } else {
      pending.completer.complete(message['result']);
    }
  }

  void _reply(Object id, Object? result) {
    _send({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  void _replyError(Object id, int code, String message, Object? data) {
    _send({
      'jsonrpc': '2.0',
      'id': id,
      'error': AcpRpcError(code, message, data: data).toJson(),
    });
  }

  void _send(JsonMap message) {
    if (_closed) return;
    // jsonEncode escapes every newline inside strings, so one message is
    // always one line.
    try {
      _output.add(utf8.encode('${jsonEncode(message)}\n'));
    } catch (_) {
      // The sink is gone: the process ended under us. Wind down.
      unawaited(close());
    }
  }

  void _onInputError(Object error, StackTrace stack) {
    _malformed.add(AcpMalformedLine('', 'input error: $error'));
  }

  void _onInputDone() {
    unawaited(close());
  }

  void _failAllPending() {
    final calls = List.of(_pending.values);
    _pending.clear();
    for (final call in calls) {
      call.completer.completeError(AcpPeerClosed(call.method));
    }
    _incoming.clear();
  }
}

class _PendingCall {
  _PendingCall(this.method);

  final String method;
  final completer = Completer<Object?>();
}
