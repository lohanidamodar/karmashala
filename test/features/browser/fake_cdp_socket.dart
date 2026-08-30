import 'dart:async';
import 'dart:convert';

import 'package:chitragupta/src/features/browser/data/cdp_socket.dart';

/// Thrown by a [FakeCdpSocket] responder to make the browser reply with a CDP
/// protocol error instead of a result.
class CdpFault implements Exception {
  CdpFault(this.code, this.message, {this.data});
  final int code;
  final String message;
  final String? data;
}

/// A scriptable [CdpSocket] — the whole point of the [CdpSocket] seam.
///
/// Records outbound frames, answers them through [responder], and can emit
/// events or drop the connection on demand, so correlation, timeouts and
/// disconnect handling are all testable without a browser.
class FakeCdpSocket implements CdpSocket {
  FakeCdpSocket({this.responder});

  final _controller = StreamController<String>.broadcast();

  /// Every frame the client sent, as raw JSON.
  final List<String> sent = [];

  /// Answers a command. Return the `result` map, or throw a [CdpFault] to
  /// answer with an error. Returning null leaves the command unanswered.
  FutureOr<Map<String, Object?>?> Function(
    String method,
    Map<String, Object?> params,
  )?
  responder;

  /// Set to throw from [send], simulating a socket that died mid-write.
  Object? sendError;

  bool closed = false;

  @override
  Stream<String> get messages => _controller.stream;

  /// The decoded frames the client sent.
  List<Map<String, Object?>> get sentFrames => [
    for (final frame in sent) jsonDecode(frame) as Map<String, Object?>,
  ];

  /// Params of the first frame for [method], or null if it was never sent.
  Map<String, Object?>? paramsFor(String method) {
    for (final frame in sentFrames) {
      if (frame['method'] == method) {
        return (frame['params'] as Map<String, Object?>?) ?? const {};
      }
    }
    return null;
  }

  /// Method names in the order they were sent.
  List<String> get methods => [
    for (final frame in sentFrames) frame['method']! as String,
  ];

  @override
  void send(String data) {
    if (sendError != null) throw sendError!;
    sent.add(data);
    final frame = jsonDecode(data) as Map<String, Object?>;
    final id = frame['id']! as int;
    final method = frame['method']! as String;
    final params = (frame['params'] as Map<String, Object?>?) ?? const {};
    final handler = responder;
    if (handler == null) return;
    scheduleMicrotask(() async {
      try {
        final result = await handler(method, params);
        if (result == null) return;
        respond(id, result);
      } on CdpFault catch (fault) {
        respondWithError(fault.code, fault.message, id: id, data: fault.data);
      }
    });
  }

  /// Sends a successful reply for [id].
  void respond(int id, Map<String, Object?> result) =>
      emit(jsonEncode({'id': id, 'result': result}));

  /// Sends an error reply for [id].
  void respondWithError(
    int code,
    String message, {
    required int id,
    String? data,
  }) => emit(
    jsonEncode({
      'id': id,
      'error': {'code': code, 'message': message, 'data': ?data},
    }),
  );

  /// Sends an unsolicited event.
  void emitEvent(String method, [Map<String, Object?> params = const {}]) =>
      emit(jsonEncode({'method': method, 'params': params}));

  /// Sends a raw frame, valid CDP or not.
  void emit(String raw) {
    if (!_controller.isClosed) _controller.add(raw);
  }

  /// Simulates the browser going away without a clean close.
  void drop() {
    if (!_controller.isClosed) _controller.close();
  }

  @override
  Future<void> close() async {
    closed = true;
    drop();
  }
}
