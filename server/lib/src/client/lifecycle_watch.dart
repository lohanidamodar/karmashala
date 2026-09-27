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
  final _mcpCalls = StreamController<McpCallMessage>();
  final _companionCalls = StreamController<CompanionCallMessage>();
  final _companionEvents = StreamController<CompanionEventMessage>();
  final _automationCalls = StreamController<AutomationCallMessage>();

  final _agentStatuses = StreamController<AgentStatusMessage>();
  final _paneTailsWanted = StreamController<PaneTailsWantedMessage>();
  final _pairings = <int, Completer<PairedMessage>>{};
  final _checks = <int, Completer<ChecksRanMessage>>{};
  final _prompts = <int, Completer<PromptAnsweredMessage>>{};
  final _serverCalls = <int, Completer<Map<String, Object?>>>{};
  var _lastRequestId = 2;
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

  /// What the agent in each session the host holds was doing when it
  /// answered, as `HostedAgentStatus.toJson`.
  late final List<Map<String, Object?>> statusSnapshot;

  /// Every agent status after [statusSnapshot], buffered like [events].
  Stream<AgentStatusMessage> get agentStatuses => _agentStatuses.stream;

  /// Asks the host to answer a prompt the agent in a session it holds has
  /// open — `PromptAnswerRequest.toJson` — and completes with how it ended.
  Future<PromptAnsweredMessage> answerPrompt(Map<String, Object?> request) {
    if (_done.isCompleted) {
      return Future.error(
        const HostLifecycleWatchRefused('the host link is closed'),
      );
    }
    final requestId = ++_lastRequestId;
    final answer = _prompts[requestId] = Completer<PromptAnsweredMessage>();
    _write(PromptAnswerMessage(requestId: requestId, request: request));
    return answer.future;
  }

  /// Every event after [snapshot], in order. Single-subscription, so events
  /// arriving before anyone listens are buffered, not lost.
  Stream<LifecycleEvent> get events => _events.stream;

  /// Every hook after [hookSnapshot], buffered like [events]. None is held:
  /// the agent was answered by the time it arrives.
  Stream<AgentHookEvent> get hooks => _hooks.stream;

  /// Each agent tool call the daemon forwards, once this client has offered
  /// tools with [offerMcpTools]; answer each with [answerMcpCall].
  Stream<McpCallMessage> get mcpCalls => _mcpCalls.stream;

  /// Makes this client the one that runs agents' tools, with [tools] as the
  /// catalogue the daemon serves — and keeps serving when this client is gone.
  void offerMcpTools(List<Map<String, Object?>> tools) =>
      _write(McpToolsMessage(tools));

  /// How the call [callId] ended: [result], or the [error] text when it failed.
  void answerMcpCall(int callId, {Object? result, String? error}) => _write(
    error == null
        ? McpResultMessage.success(callId, result)
        : McpResultMessage.failure(callId, error),
  );

  /// Each companion call the host forwards, once this client has said it is
  /// the app with [attachCompanion]; answer each with [answerCompanionCall].
  Stream<CompanionCallMessage> get companionCalls => _companionCalls.stream;

  /// What the host's companion tells this client: device rows moved, a
  /// pairing window this client opened ended.
  Stream<CompanionEventMessage> get companionEvents => _companionEvents.stream;

  /// Makes this client the app the host forwards companion calls to, with its
  /// embedded relay at [localRelayUrl] (null: none). How phones are served is
  /// the server's config: [serverCall] `server.config.set` changes it.
  void attachCompanion({String? localRelayUrl}) =>
      _write(CompanionAttachMessage(localRelayUrl: localRelayUrl));

  /// Asks the server one administrative question (`ServerMethod`) and
  /// completes with its answer. Throws [HostLifecycleWatchRefused] with the
  /// server's reason when it refuses, or when the link closes first.
  Future<Map<String, Object?>> serverCall(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) {
    if (_done.isCompleted) {
      return Future.error(
        const HostLifecycleWatchRefused('the host link is closed'),
      );
    }
    final requestId = ++_lastRequestId;
    final answer = _serverCalls[requestId] = Completer<Map<String, Object?>>();
    _write(
      ServerCallMessage(
        requestId: requestId,
        method: method,
        arguments: arguments,
      ),
    );
    return answer.future;
  }

  /// How the companion call [callId] ended: [result], or the companion error
  /// [code] and [message] the phone is refused with.
  void answerCompanionCall(
    int callId, {
    Map<String, Object?>? result,
    String? code,
    String? message,
  }) => _write(
    code == null
        ? CompanionResultMessage.success(callId, result ?? const {})
        : CompanionResultMessage.failure(
            callId,
            code: code,
            message: message ?? code,
          ),
  );

  /// News from the desktop for the host's companion.
  void noticeCompanion(CompanionNoticeMessage notice) => _write(notice);

  /// Each automation call the host forwards, once this client has said it is
  /// the app with [noticeAutomations]; answer each with
  /// [answerAutomationCall].
  Stream<AutomationCallMessage> get automationCalls => _automationCalls.stream;

  /// "I am the app" ([AutomationNoticeKind.ready]).
  void noticeAutomations(AutomationNoticeKind kind) =>
      _write(AutomationNoticeMessage(kind));

  /// How the automation call [callId] ended: done, or [error].
  void answerAutomationCall(int callId, {String? error}) => _write(
    error == null
        ? AutomationResultMessage.success(callId)
        : AutomationResultMessage.failure(callId, error),
  );

  /// Runs [sessionId]'s project checks in sessions the host owns.
  Future<ChecksRanMessage> runChecks(String sessionId) {
    if (_done.isCompleted) {
      return Future.error(
        const HostLifecycleWatchRefused('the host link is closed'),
      );
    }
    final requestId = ++_lastRequestId;
    final answer = _checks[requestId] = Completer<ChecksRanMessage>();
    _write(ChecksRunMessage(requestId: requestId, sessionId: sessionId));
    return answer.future;
  }

  /// Opens a pairing window at the host. Its end arrives on [companionEvents]
  /// under the answer's `requestId`. Throws [HostLifecycleWatchRefused] with
  /// the host's reason when it will not open one.
  Future<PairedMessage> pairCompanion({
    required int capabilities,
    String relay = '',
    bool relayIsLocal = false,
  }) {
    if (_done.isCompleted) {
      return Future.error(
        const HostLifecycleWatchRefused('the host link is closed'),
      );
    }
    final requestId = ++_lastRequestId;
    final answer = _pairings[requestId] = Completer<PairedMessage>();
    _write(
      PairMessage(
        requestId: requestId,
        capabilities: capabilities,
        relay: relay,
        relayIsLocal: relayIsLocal,
      ),
    );
    return answer.future;
  }

  /// Throws when [message] cannot be encoded — a result that is not JSON —
  /// so the caller can answer with that instead of leaving the call open.
  void _write(HostMessage message) {
    if (_done.isCompleted) return;
    final bytes = message.toFrame().encode();
    try {
      _connection.add(bytes);
    } on Object {
      // The link went down between the check and the write.
    }
  }

  /// Tells the server every terminal pane this client has now, as facts —
  /// the whole list, each time it changes.
  void reportPanes(List<PaneFacts> panes) => _write(PaneFactsMessage(panes));

  /// Each time the server wants some panes' bottom rows with the next
  /// [reportPanes]. Buffered like [events].
  Stream<PaneTailsWantedMessage> get paneTailsWanted => _paneTailsWanted.stream;

  /// Completes when the link ends, from either side.
  Future<void> get done => _done.future;

  /// Says hello, asks to watch, and waits for the snapshot. Throws
  /// [HostLifecycleWatchRefused] when the host refuses either — a host that
  /// predates the feed refuses `watch` — or does not answer in [answerWithin].
  /// [runByClient] names the session rows this client runs in its own panes.
  static Future<HostLifecycleWatch> over(
    HostConnection connection, {
    String clientId = 'karmashala-lifecycle',
    Duration answerWithin = const Duration(seconds: 10),
    List<String> runByClient = const [],
  }) async {
    final watch = HostLifecycleWatch._(connection);
    try {
      await watch._start(clientId, answerWithin, runByClient);
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

  Future<void> _start(
    String clientId,
    Duration answerWithin,
    List<String> runByClient,
  ) async {
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
    _connection.add(
      WatchMessage(2, runByClient: runByClient).toFrame().encode(),
    );
    final watching = await _expect<WatchingMessage>(answerWithin);
    snapshot = List.unmodifiable(watching.sessions);
    hookSnapshot = List.unmodifiable(watching.hooks);
    statusSnapshot = List.unmodifiable(watching.statuses);
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
    if (message is McpCallMessage) {
      if (!_mcpCalls.isClosed) _mcpCalls.add(message);
      return;
    }
    if (message is CompanionCallMessage) {
      if (!_companionCalls.isClosed) _companionCalls.add(message);
      return;
    }
    if (message is CompanionEventMessage) {
      if (!_companionEvents.isClosed) _companionEvents.add(message);
      return;
    }
    if (message is PairedMessage) {
      _pairings.remove(message.requestId)?.complete(message);
      return;
    }
    if (message is AutomationCallMessage) {
      if (!_automationCalls.isClosed) _automationCalls.add(message);
      return;
    }

    if (message is ChecksRanMessage) {
      _checks.remove(message.requestId)?.complete(message);
      return;
    }
    if (message is AgentStatusMessage) {
      if (!_agentStatuses.isClosed) _agentStatuses.add(message);
      return;
    }
    if (message is PaneTailsWantedMessage) {
      if (!_paneTailsWanted.isClosed) _paneTailsWanted.add(message);
      return;
    }
    if (message is PromptAnsweredMessage) {
      _prompts.remove(message.requestId)?.complete(message);
      return;
    }
    if (message is ServerResultMessage) {
      final call = _serverCalls.remove(message.requestId);
      if (call == null) return;
      final result = message.result;
      if (result != null) {
        call.complete(result);
      } else {
        call.completeError(
          HostLifecycleWatchRefused(message.message ?? 'refused'),
        );
      }
      return;
    }
    if (message is ErrorMessage) {
      final pairing = _pairings.remove(message.requestId);
      if (pairing != null) {
        pairing.completeError(HostLifecycleWatchRefused(message.message));
        return;
      }
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
    if (!_mcpCalls.isClosed) unawaited(_mcpCalls.close());
    if (!_companionCalls.isClosed) unawaited(_companionCalls.close());
    if (!_companionEvents.isClosed) unawaited(_companionEvents.close());
    if (!_automationCalls.isClosed) unawaited(_automationCalls.close());

    if (!_agentStatuses.isClosed) unawaited(_agentStatuses.close());
    if (!_paneTailsWanted.isClosed) unawaited(_paneTailsWanted.close());
    for (final pairing in _pairings.values) {
      pairing.completeError(
        const HostLifecycleWatchRefused('the host link closed'),
      );
    }
    _pairings.clear();
    for (final checks in _checks.values) {
      checks.completeError(
        const HostLifecycleWatchRefused('the host link closed'),
      );
    }
    _checks.clear();
    for (final prompt in _prompts.values) {
      prompt.completeError(
        const HostLifecycleWatchRefused('the host link closed'),
      );
    }
    _prompts.clear();
    for (final call in _serverCalls.values) {
      call.completeError(
        const HostLifecycleWatchRefused('the host link closed'),
      );
    }
    _serverCalls.clear();
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
