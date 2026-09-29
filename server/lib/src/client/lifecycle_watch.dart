import 'dart:async';
import 'dart:io';

import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import '../transport/socket_transport.dart';
import '../transport/transport.dart';
import 'connection_channel.dart';

/// One host's lifecycle feed: the facts it holds now, then each change — and
/// the agent hooks it took, the latest per session, then each one.
///
/// On a client's one link ([onLink], slice 5e), or its own over any
/// [HostConnection] ([over]) or a local socket ([connect]).
class HostLifecycleWatch {
  HostLifecycleWatch._(this._link, this._owns);

  final HostClientLink _link;
  final bool _owns;
  final _events = StreamController<LifecycleEvent>();
  final _hooks = StreamController<AgentHookEvent>();
  final _companionEvents = StreamController<CompanionEventMessage>();
  final _agentStatuses = StreamController<AgentStatusMessage>();
  final _done = Completer<void>();
  StreamSubscription<HostMessage>? _messages;

  /// What the host said about itself on the handshake.
  late final WelcomeMessage welcome;

  /// Every session the host knew when it answered, and when that was.
  late final List<HostSessionFacts> snapshot;
  late final DateTime snapshotObservedAt;

  /// The latest hook per agent session when the host answered, oldest first.
  late final List<AgentHookEvent> hookSnapshot;

  /// What the agent in each session the host holds was doing when it
  /// answered, as `HostedAgentStatus.toJson`.
  late final List<Map<String, Object?>> statusSnapshot;

  /// Every agent status after [statusSnapshot], buffered like [events].
  Stream<AgentStatusMessage> get agentStatuses => _agentStatuses.stream;

  /// Every event after [snapshot], in order. Single-subscription, so events
  /// arriving before anyone listens are buffered, not lost.
  Stream<LifecycleEvent> get events => _events.stream;

  /// Every hook after [hookSnapshot], buffered like [events].
  Stream<AgentHookEvent> get hooks => _hooks.stream;

  /// What the host's companion tells this client: a pairing window this
  /// client opened ended.
  Stream<CompanionEventMessage> get companionEvents => _companionEvents.stream;

  /// Completes when the link ends, from either side.
  Future<void> get done => _done.future;

  /// Asks the host to answer a prompt the agent in a session it holds has
  /// open — `PromptAnswerRequest.toJson` — and completes with how it ended.
  /// Bounded by [kPromptAnswerWithin], so a card does not wait out a resumed
  /// link's grace; a timeout is [HostLifecycleWatchRefused.timedOut].
  Future<PromptAnsweredMessage> answerPrompt(Map<String, Object?> request) =>
      _ask<PromptAnsweredMessage>(
        (id) => PromptAnswerMessage(requestId: id, request: request),
        kPromptAnswerWithin,
      );

  /// Asks the server one administrative question (`ServerMethod`) and
  /// completes with its answer. Throws [HostLifecycleWatchRefused] with the
  /// server's reason when it refuses, or when the link closes first.
  Future<Map<String, Object?>> serverCall(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final answer = await _ask<ServerResultMessage>(
      (id) => ServerCallMessage(
        requestId: id,
        method: method,
        arguments: arguments,
      ),
    );
    return answer.result ??
        (throw HostLifecycleWatchRefused(answer.message ?? 'refused'));
  }

  /// News from the desktop for the host's companion: its pairing dialog
  /// closed.
  void noticeCompanion(CompanionNoticeMessage notice) => _link.send(notice);

  /// Opens a pairing window at the host. Its end arrives on [companionEvents]
  /// under the answer's `requestId`. Throws [HostLifecycleWatchRefused] with
  /// the host's reason when it will not open one.
  Future<PairedMessage> pairCompanion({
    required int capabilities,
    String relay = '',
    bool relayIsLocal = false,
  }) => _ask<PairedMessage>(
    (id) => PairMessage(
      requestId: id,
      capabilities: capabilities,
      relay: relay,
      relayIsLocal: relayIsLocal,
    ),
  );

  Future<T> _ask<T extends HostMessage>(
    HostMessage Function(int id) build, [
    Duration? within,
  ]) async {
    if (_done.isCompleted) {
      throw const HostLifecycleWatchRefused('the host link is closed');
    }
    try {
      return await _link.request<T>(build, within);
    } on HostLinkException catch (error) {
      throw HostLifecycleWatchRefused(error.message, timedOut: error.timedOut);
    }
  }

  /// Watches over [connection], a link of its own: says hello, asks to
  /// watch, and waits for the snapshot. Throws [HostLifecycleWatchRefused]
  /// when the host refuses either — or does not answer in [answerWithin].
  /// [runByClient] names the session rows this client runs in its own panes.
  static Future<HostLifecycleWatch> over(
    HostConnection connection, {
    String clientId = 'karmashala-lifecycle',
    Duration answerWithin = const Duration(seconds: 10),
    List<String> runByClient = const [],
  }) async {
    final HostClientLink link;
    try {
      link = await HostClientLink.open(
        ConnectionChannel(connection),
        clientId: clientId,
        features: 0,
        bound: answerWithin,
      );
    } on HostLinkException catch (error) {
      throw HostLifecycleWatchRefused(error.message);
    }
    return _start(link, true, answerWithin, runByClient);
  }

  /// Watches on a client's shared [link]; [close] then leaves the link up.
  static Future<HostLifecycleWatch> onLink(
    HostClientLink link, {
    Duration answerWithin = const Duration(seconds: 10),
    List<String> runByClient = const [],
  }) => _start(link, false, answerWithin, runByClient);

  /// Null when nothing is listening at [socketPath].
  static Future<HostLifecycleWatch?> connect(
    String socketPath, {
    String clientId = 'karmashala-lifecycle',
    Duration answerWithin = const Duration(seconds: 10),
    List<String> runByClient = const [],
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
      runByClient: runByClient,
    );
  }

  static Future<HostLifecycleWatch> _start(
    HostClientLink link,
    bool owns,
    Duration answerWithin,
    List<String> runByClient,
  ) async {
    final watch = HostLifecycleWatch._(link, owns);
    watch._messages = link.messages.listen(watch._onMessage);
    unawaited(link.done.then((_) => watch._end()));
    try {
      final watching = await watch._ask<WatchingMessage>(
        (id) => WatchMessage(id, runByClient: runByClient),
        answerWithin,
      );
      watch
        ..welcome = link.welcome
        ..snapshot = List.unmodifiable(watching.sessions)
        ..hookSnapshot = List.unmodifiable(watching.hooks)
        ..statusSnapshot = List.unmodifiable(watching.statuses)
        ..snapshotObservedAt = watching.observedAt;
    } on Object {
      await watch.close();
      rethrow;
    }
    return watch;
  }

  void _onMessage(HostMessage message) {
    switch (message) {
      case LifecycleMessage(:final event):
        if (!_events.isClosed) _events.add(event);
      case HookMessage(:final hook):
        if (!_hooks.isClosed) _hooks.add(hook);
      case CompanionEventMessage():
        if (!_companionEvents.isClosed) _companionEvents.add(message);
      case AgentStatusMessage():
        if (!_agentStatuses.isClosed) _agentStatuses.add(message);
      default:
        break;
    }
  }

  void _end() {
    if (_done.isCompleted) return;
    unawaited(_messages?.cancel());
    _messages = null;
    unawaited(_events.close());
    unawaited(_hooks.close());
    unawaited(_companionEvents.close());
    unawaited(_agentStatuses.close());
    _done.complete();
  }

  /// Stops watching; hangs up a link of its own. The host's sessions are
  /// untouched.
  Future<void> close() async {
    _end();
    if (_owns) await _link.close();
  }
}

/// How long a prompt answer waits for the host's reply, as a data request
/// does. A reply later than this is the host's to refuse: the answer names
/// its prompt (`prompt.answer.ask`).
const Duration kPromptAnswerWithin = Duration(seconds: 20);

class HostLifecycleWatchRefused implements Exception {
  const HostLifecycleWatchRefused(this.message, {this.timedOut = false});
  final String message;

  /// The bound ran out: what was asked may still have been done.
  final bool timedOut;
  @override
  String toString() => 'HostLifecycleWatchRefused: $message';
}
