import 'dart:async';
import 'dart:io';

import 'package:karmashala_relay/karmashala_relay.dart' show hooksListenIdOf;
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:karmashala_remote/remote.dart' show Backoff;

enum HooksListenerState {
  /// Nothing to listen for: no enabled webhook, or no relay.
  off,
  connecting,
  listening,

  /// Between attempts, after a drop or a refusal.
  waiting,
}

/// The server's end of the hooks route: one WebSocket to its relay at
/// `v1/hooks/<listen key>`, reconnected with backoff while there is anything
/// to listen for. Each call frame is answered by [answer].
class HooksRelayListener {
  HooksRelayListener({
    required Future<HookAnswer> Function(HookCall call) answer,
    Backoff Function()? backoff,
    Future<WebSocket> Function(Uri endpoint)? connect,
    void Function(String message)? log,
  }) : _answer = answer,
       _backoff = (backoff ?? Backoff.new)(),
       _connect = connect ?? _defaultConnect,
       _log = log;

  final Future<HookAnswer> Function(HookCall call) _answer;
  final Backoff _backoff;
  final Future<WebSocket> Function(Uri endpoint) _connect;
  final void Function(String message)? _log;

  Uri? _relay;
  String? _key;
  WebSocket? _socket;
  Timer? _retry;
  int _generation = 0;

  HooksListenerState state = HooksListenerState.off;

  /// The listen id the relay confirmed, once it has.
  String? listenId;

  /// Why the last attempt did not hold, in words; null while listening.
  String? problem;

  /// Attempts since the last one that held.
  int get attempts => _backoff.attempts;

  /// Sockets that reached `ready`, ever.
  int connections = 0;

  static Future<WebSocket> _defaultConnect(Uri endpoint) => WebSocket.connect(
    endpoint.toString(),
  ).timeout(const Duration(seconds: 15));

  /// Listen on [relay] with [listenKey], or stop when either is null. The
  /// same pair again changes nothing.
  void listenOn(Uri? relay, String? listenKey) {
    if (relay == _relay && listenKey == _key) return;
    _stop();
    _relay = relay;
    _key = listenKey;
    if (relay == null || listenKey == null) return;
    _backoff.reset();
    unawaited(_open(_generation));
  }

  Future<void> close() async => _stop();

  void _stop() {
    _generation++;
    _retry?.cancel();
    _retry = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close(kClosePeerLeft, 'stopped'));
    _relay = null;
    _key = null;
    state = HooksListenerState.off;
    listenId = null;
    problem = null;
  }

  Uri _endpoint(Uri relay, String key) => relay.replace(
    path: joinRelayPath(relay.path, hooksListenPath(key)),
    query: null,
  );

  Future<void> _open(int generation) async {
    final relay = _relay;
    final key = _key;
    if (relay == null || key == null) return;
    state = HooksListenerState.connecting;
    final WebSocket socket;
    try {
      socket = await _connect(_endpoint(relay, key));
    } on Object catch (error) {
      if (generation != _generation) return;
      _wait(
        error is WebSocketException
            ? 'the relay did not take the hooks listener — it may predate '
                  'webhooks, or be unreachable'
            : 'the relay could not be reached',
        generation,
      );
      return;
    }
    if (generation != _generation) {
      unawaited(socket.close(kClosePeerLeft, 'stopped'));
      return;
    }
    socket.pingInterval = const Duration(seconds: 25);
    _socket = socket;
    final expected = hooksListenIdOf(key);
    socket.listen(
      (frame) {
        final read = HookFrame.tryDecode(frame);
        switch (read) {
          case HooksReady(:final listenId) when listenId == expected:
            this.listenId = listenId;
            state = HooksListenerState.listening;
            problem = null;
            connections++;
            _backoff.reset();
            _log?.call('webhooks: listening on the relay');
          case HooksReady():
            problem = 'the relay derived a different listen id';
            unawaited(socket.close(kClosePeerFailed, 'listen id mismatch'));
          case HookCall():
            unawaited(_reply(socket, read));
          default:
            break;
        }
      },
      onDone: () {
        if (generation != _generation) return;
        _socket = null;
        listenId = null;
        _wait(problem ?? 'the relay connection closed', generation);
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  Future<void> _reply(WebSocket socket, HookCall call) async {
    HookAnswer answer;
    try {
      answer = await _answer(call);
    } on Object {
      answer = HookAnswer(
        id: call.id,
        status: HookStatus.failed,
        body: const {'error': 'failed'},
      );
    }
    if (socket.readyState == WebSocket.open) socket.add(answer.encode());
  }

  void _wait(String why, int generation) {
    state = HooksListenerState.waiting;
    problem = why;
    final delay = _backoff.next();
    _log?.call('webhooks: $why; trying again in ${delay.inSeconds} s');
    _retry = Timer(delay, () {
      if (generation == _generation) unawaited(_open(generation));
    });
  }
}
