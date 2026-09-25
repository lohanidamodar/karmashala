import 'dart:async';
import 'dart:io';

import '../protocol/frame.dart';
import '../protocol/messages.dart';
import '../protocol/wire.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';

/// One host's lifecycle feed: the facts it holds now, then each change — and
/// the agent hooks it took, the latest per session, then each one.
///
/// Built over any [HostConnection] — a unix socket, an SSH channel, a pipe —
/// with [over], or on a local socket with [connect].
class HostLifecycleWatch {
  HostLifecycleWatch._(this._connection);

  final HostConnection _connection;
  final _parser = FrameParser();
  final _events = StreamController<LifecycleEvent>();
  final _hooks = StreamController<AgentHookEvent>();
  final _done = Completer<void>();
  StreamSubscription<List<int>>? _incoming;
  Completer<HostMessage>? _awaiting;

  /// What the host said about itself on the handshake.
  late final WelcomeMessage welcome;

  /// Every session the host knew when it answered, and when that was.
  late final List<HostSessionFacts> snapshot;
  late final DateTime snapshotObservedAt;

  /// The latest hook per agent session when the host answered, oldest first.
  late final List<AgentHookEvent> hookSnapshot;

  /// Every event after [snapshot], in order. Single-subscription, so events
  /// arriving before anyone listens are buffered, not lost.
  Stream<LifecycleEvent> get events => _events.stream;

  /// Every hook after [hookSnapshot], buffered like [events].
  Stream<AgentHookEvent> get hooks => _hooks.stream;

  /// Completes when the link ends, from either side.
  Future<void> get done => _done.future;

  /// Says hello, asks to watch, and waits for the snapshot. Throws
  /// [HostLifecycleWatchRefused] when the host refuses either — a host that
  /// predates the feed refuses `watch` — or does not answer in [answerWithin].
  static Future<HostLifecycleWatch> over(
    HostConnection connection, {
    String clientId = 'karmashala-lifecycle',
    Duration answerWithin = const Duration(seconds: 10),
  }) async {
    final watch = HostLifecycleWatch._(connection);
    try {
      await watch._start(clientId, answerWithin);
    } on Object {
      await watch.close();
      rethrow;
    }
    return watch;
  }

  /// Null when nothing is listening at [socketPath].
  static Future<HostLifecycleWatch?> connect(
    String socketPath, {
    String clientId = 'karmashala-lifecycle',
    Duration answerWithin = const Duration(seconds: 10),
  }) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } on SocketException {
      return null;
    }
    return over(
      SocketHostConnection(socket, socketPath),
      clientId: clientId,
      answerWithin: answerWithin,
    );
  }

  Future<void> _start(String clientId, Duration answerWithin) async {
    _incoming = _connection.incoming.listen(
      _onBytes,
      onError: (Object error) => _end(error),
      onDone: () => _end(const HostLifecycleWatchRefused('the host closed')),
      cancelOnError: true,
    );
    _connection.add(
      HelloMessage(requestId: 1, clientId: clientId).toFrame().encode(),
    );
    welcome = await _expect<WelcomeMessage>(answerWithin);
    _connection.add(const WatchMessage(2).toFrame().encode());
    final watching = await _expect<WatchingMessage>(answerWithin);
    snapshot = List.unmodifiable(watching.sessions);
    hookSnapshot = List.unmodifiable(watching.hooks);
    snapshotObservedAt = watching.observedAt;
  }

  Future<T> _expect<T extends HostMessage>(Duration within) async {
    final answer = _awaiting = Completer<HostMessage>();
    final HostMessage message;
    try {
      message = await answer.future.timeout(
        within,
        onTimeout: () =>
            throw const HostLifecycleWatchRefused('the host did not answer'),
      );
    } finally {
      _awaiting = null;
    }
    if (message is ErrorMessage) {
      throw HostLifecycleWatchRefused(message.message);
    }
    return message as T;
  }

  void _onBytes(List<int> chunk) {
    final List<Frame> frames;
    try {
      frames = _parser.add(chunk);
    } on FrameFormatException catch (e) {
      // Nothing after an impossible header can be trusted.
      _end(HostLifecycleWatchRefused(e.message));
      return;
    }
    for (final frame in frames) {
      final HostMessage message;
      try {
        message = decodeMessage(frame);
      } on WireFormatException {
        // A newer host's event this build cannot read: skip it, keep the feed.
        continue;
      }
      _onMessage(message);
    }
  }

  void _onMessage(HostMessage message) {
    final awaiting = _awaiting;
    if (message is LifecycleMessage) {
      if (!_events.isClosed) _events.add(message.event);
      return;
    }
    if (message is HookMessage) {
      if (!_hooks.isClosed) _hooks.add(message.hook);
      return;
    }
    if (awaiting != null &&
        !awaiting.isCompleted &&
        (message is WelcomeMessage ||
            message is WatchingMessage ||
            message is ErrorMessage)) {
      awaiting.complete(message);
    }
  }

  void _end(Object reason) {
    final awaiting = _awaiting;
    if (awaiting != null && !awaiting.isCompleted) {
      awaiting.completeError(
        reason is HostLifecycleWatchRefused
            ? reason
            : HostLifecycleWatchRefused('$reason'),
      );
    }
    if (!_events.isClosed) unawaited(_events.close());
    if (!_hooks.isClosed) unawaited(_hooks.close());
    if (!_done.isCompleted) _done.complete();
  }

  /// Stops watching and hangs up; the host's sessions are untouched.
  Future<void> close() async {
    await _incoming?.cancel();
    _incoming = null;
    _end(const HostLifecycleWatchRefused('closed'));
    await _connection.close();
  }
}

class HostLifecycleWatchRefused implements Exception {
  const HostLifecycleWatchRefused(this.message);
  final String message;
  @override
  String toString() => 'HostLifecycleWatchRefused: $message';
}
