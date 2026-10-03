import 'dart:async';

import '../json.dart';

/// A request the other side sent and is waiting on. Answer it exactly once
/// with [respond] or [fail]; a second answer, or one after the request was
/// cancelled, is dropped.
final class AcpIncomingRequest {
  AcpIncomingRequest({
    required this.id,
    required this.method,
    required this.params,
    required this._onRespond,
    required this._onFail,
  });

  final Object id;
  final String method;
  final Object? params;

  final void Function(Object? result) _onRespond;
  final void Function(int code, String message, Object? data) _onFail;
  final _cancelled = Completer<void>();
  bool _answered = false;

  /// [params] as an object, or an empty one when the request carried none.
  JsonMap get paramsMap => asJsonMap(params) ?? const {};

  bool get isAnswered => _answered;

  /// The other side withdrew the request (`$/cancel_request`); it has already
  /// been answered with -32800, so a handler should stop its work.
  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get cancelled => _cancelled.future;

  void respond(Object? result) {
    if (_answered) return;
    _answered = true;
    _onRespond(result);
  }

  void fail(int code, String message, {Object? data}) {
    if (_answered) return;
    _answered = true;
    _onFail(code, message, data);
  }

  /// Called by the peer, never by a handler.
  void markCancelled() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// A notification the other side sent.
final class AcpNotification {
  const AcpNotification(this.method, this.params);

  final String method;
  final Object? params;

  JsonMap get paramsMap => asJsonMap(params) ?? const {};
}

/// A line the peer could not treat as a JSON-RPC message, kept for a log
/// rather than thrown: an agent's stray stdout must not take the session down.
final class AcpMalformedLine {
  const AcpMalformedLine(this.line, this.reason);

  final String line;
  final String reason;

  @override
  String toString() => 'AcpMalformedLine($reason): $line';
}
