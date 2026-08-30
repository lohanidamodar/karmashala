import 'dart:async';

import '../domain/browser_failure.dart';
import '../domain/cdp_message.dart';
import 'cdp_protocol.dart';
import 'cdp_socket.dart';

/// Correlates CDP requests with their replies over a single [CdpSocket], and
/// republishes everything else as events.
///
/// The contract that matters: **a pending request never resolves successfully
/// once the peer is gone**. When the socket closes — the user quit Chrome, the
/// tab was closed, the target crashed — every outstanding request completes
/// with a [BrowserException], and every later [send] throws immediately.
class CdpConnection {
  CdpConnection(
    this._socket, {
    this.defaultTimeout = const Duration(seconds: 20),
    this.onProtocolError,
  }) {
    _subscription = _socket.messages.listen(
      _handleFrame,
      onError: (Object error) => _shutdown(
        BrowserException(
          BrowserFailure.disconnected,
          describeBrowserFailure(BrowserFailure.disconnected),
          cause: error,
        ),
      ),
      onDone: () => _shutdown(
        BrowserException(
          BrowserFailure.disconnected,
          describeBrowserFailure(BrowserFailure.disconnected),
        ),
      ),
      cancelOnError: false,
    );
  }

  final CdpSocket _socket;
  final Duration defaultTimeout;

  /// Called for frames that are not decodable CDP. One bad frame does not
  /// tear down the connection, but it must not vanish silently either.
  final void Function(CdpProtocolException error)? onProtocolError;

  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _events = StreamController<CdpEvent>.broadcast();
  final _closed = Completer<BrowserException?>();

  late final StreamSubscription<String> _subscription;
  int _nextId = 0;
  BrowserException? _failure;

  /// Every event frame the peer sends, in arrival order.
  Stream<CdpEvent> get events => _events.stream;

  /// Events with exactly this `method`.
  Stream<CdpEvent> on(String method) =>
      _events.stream.where((event) => event.method == method);

  /// Whether the peer has gone away (or [close] was called).
  bool get isClosed => _closed.isCompleted;

  /// Completes when the connection ends, with the failure that ended it, or
  /// null if it was closed deliberately.
  Future<BrowserException?> get done => _closed.future;

  /// Sends `method` and waits for its reply.
  ///
  /// Throws [BrowserException] with [BrowserFailure.protocolError] when the
  /// browser rejects the command, [BrowserFailure.timeout] when no reply
  /// arrives, and [BrowserFailure.disconnected] when the peer vanishes.
  Future<Map<String, Object?>> send(
    String method, {
    Map<String, Object?>? params,
    String? sessionId,
    Duration? timeout,
  }) {
    final failure = _failure;
    if (isClosed) {
      throw failure ??
          BrowserException(
            BrowserFailure.disconnected,
            describeBrowserFailure(
              BrowserFailure.disconnected,
              detail: 'the connection was already closed',
            ),
          );
    }

    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      _socket.send(
        encodeCdpCommand(
          id: id,
          method: method,
          params: params,
          sessionId: sessionId,
        ),
      );
    } on Object catch (error) {
      _pending.remove(id);
      throw BrowserException(
        BrowserFailure.disconnected,
        describeBrowserFailure(
          BrowserFailure.disconnected,
          detail: 'while sending $method',
        ),
        cause: error,
      );
    }

    return completer.future.timeout(
      timeout ?? defaultTimeout,
      onTimeout: () {
        _pending.remove(id);
        throw BrowserException(
          BrowserFailure.timeout,
          describeBrowserFailure(
            BrowserFailure.timeout,
            detail: '$method did not answer',
          ),
        );
      },
    );
  }

  /// Closes the socket and fails anything still outstanding.
  Future<void> close() async {
    if (!isClosed) _shutdown(null);
    await _subscription.cancel();
    await _socket.close();
    await _events.close();
  }

  void _handleFrame(String raw) {
    final CdpMessage message;
    try {
      message = decodeCdpMessage(raw);
    } on CdpProtocolException catch (error) {
      onProtocolError?.call(error);
      return;
    }

    switch (message) {
      case CdpResult(:final id, :final result):
        _pending.remove(id)?.complete(result);
      case CdpErrorMessage(:final id, :final description):
        _pending
            .remove(id)
            ?.completeError(
              BrowserException(
                BrowserFailure.protocolError,
                describeBrowserFailure(
                  BrowserFailure.protocolError,
                  detail: description,
                ),
              ),
            );
      case CdpEvent():
        if (!_events.isClosed) _events.add(message);
    }
  }

  /// Ends the connection: record the cause, then fail everything in flight.
  void _shutdown(BrowserException? failure) {
    if (_closed.isCompleted) return;
    _failure = failure;
    _closed.complete(failure);
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    final error =
        failure ??
        BrowserException(
          BrowserFailure.disconnected,
          describeBrowserFailure(
            BrowserFailure.disconnected,
            detail: 'the connection was closed locally',
          ),
        );
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    if (!_events.isClosed) _events.close();
  }
}
