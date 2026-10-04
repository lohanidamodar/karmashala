import 'dart:async';
import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart' show JsonMap;

import '../acp_transport.dart';
import 'claude_tools.dart' show jsonObject;

/// Claude answered a control request with an error, or ended before it did.
final class ClaudeControlError implements Exception {
  const ClaudeControlError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One `claude -p --input-format stream-json --output-format stream-json`
/// process: JSON lines both ways, and the control channel multiplexed on
/// them (`control_request` / `control_response`, either side asking).
final class ClaudeProcess {
  ClaudeProcess(
    this._transport, {
    required void Function(JsonMap message) onMessage,
    required Future<JsonMap?> Function(JsonMap request) onControlRequest,
    required void Function(String line) onErrorLine,
  }) : _onMessage = onMessage,
       _onControlRequest = onControlRequest {
    final stdoutDone = Completer<void>();
    _transport.output
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_line, onError: (Object _) {}, onDone: stdoutDone.complete);
    _transport.errorLines.listen((line) {
      _stderr.add(line);
      if (_stderr.length > 40) _stderr.removeAt(0);
      onErrorLine(line);
    }, onError: (Object _) {});
    // What it wrote before exiting is read before it counts as ended.
    unawaited(
      _transport.exitCode.then((code) => code, onError: (Object _) => -1).then((
        code,
      ) async {
        await stdoutDone.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        _end(code);
      }),
    );
  }

  final AcpTransport _transport;
  final void Function(JsonMap message) _onMessage;
  final Future<JsonMap?> Function(JsonMap request) _onControlRequest;
  final _pending = <String, Completer<JsonMap?>>{};
  final _ended = Completer<int>();
  final _stderr = <String>[];
  var _next = 0;

  /// Completes with the exit code once the process has gone and its output
  /// has been read.
  Future<int> get ended => _ended.future;

  bool get hasEnded => _ended.isCompleted;

  /// The last lines it wrote to stderr.
  String get stderrTail => _stderr.join('\n').trim();

  void send(JsonMap message) {
    try {
      _transport.input.add(utf8.encode('${jsonEncode(message)}\n'));
    } on Object {
      // Its stdin is gone with it; the exit says so.
    }
  }

  /// Sends a control request and completes with its `response`; throws
  /// [ClaudeControlError] for an error answer or an exit before one.
  Future<JsonMap?> control(String subtype, [JsonMap fields = const {}]) {
    if (hasEnded) {
      return Future.error(const ClaudeControlError('Claude Code has exited'));
    }
    final id = 'karmashala-${++_next}';
    final answer = Completer<JsonMap?>();
    _pending[id] = answer;
    send({
      'type': 'control_request',
      'request_id': id,
      'request': {'subtype': subtype, ...fields},
    });
    return answer.future;
  }

  /// Closes its stdin, which ends a stream-json `claude` between turns.
  Future<void> close() async {
    try {
      await _transport.input.close();
    } on Object {
      // Already closed.
    }
  }

  Future<void> kill() => _transport.kill();

  /// Whether it ended within [bound].
  Future<bool> endedWithin(Duration bound) =>
      ended.then((_) => true).timeout(bound, onTimeout: () => false);

  void _line(String line) {
    if (line.trim().isEmpty) return;
    JsonMap? message;
    try {
      message = jsonObject(jsonDecode(line));
    } on FormatException {
      return;
    }
    if (message == null) return;
    switch (message['type']) {
      case 'control_response':
        final response = jsonObject(message['response']) ?? const {};
        final answer = _pending.remove(response['request_id']);
        if (answer == null) return;
        if (response['subtype'] == 'error') {
          answer.completeError(
            ClaudeControlError('${response['error'] ?? 'refused'}'),
          );
        } else {
          answer.complete(jsonObject(response['response']));
        }
      case 'control_request':
        unawaited(
          _answer(
            message['request_id'],
            jsonObject(message['request']) ?? const {},
          ),
        );
      default:
        _onMessage(message);
    }
  }

  Future<void> _answer(Object? id, JsonMap request) async {
    try {
      final response = await _onControlRequest(request);
      send({
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': id,
          'response': ?response,
        },
      });
    } on Object catch (error) {
      send({
        'type': 'control_response',
        'response': {'subtype': 'error', 'request_id': id, 'error': '$error'},
      });
    }
  }

  void _end(int code) {
    if (_ended.isCompleted) return;
    final words = stderrTail.isEmpty
        ? 'Claude Code exited with code $code'
        : 'Claude Code exited with code $code: $stderrTail';
    for (final answer in _pending.values) {
      answer.completeError(ClaudeControlError(words));
    }
    _pending.clear();
    _ended.complete(code);
  }
}
