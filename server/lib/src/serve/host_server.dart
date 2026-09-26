import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../automations/automation_handler.dart';
import '../companion/companion_handler.dart';
import '../domain/host_session.dart';
import '../domain/session_lifecycle.dart';
import '../domain/session_registry.dart';
import '../hooks/hook_holds.dart';
import '../host_version.dart';
import '../mcp/mcp_tool_relay.dart';
import '../protocol/frame.dart';
import '../protocol/messages.dart';
import '../protocol/wire.dart';
import '../pty/pty.dart';
import '../server/server_admin.dart';
import '../status/daemon_prompt_answers.dart';
import '../transport/transport.dart';
import 'lifecycle_feed.dart';

/// Serves the protocol to whoever connects, over whatever carried them. It
/// knows nothing about SSH, and must not (see transport.dart).
class HostServer {
  HostServer({
    required this.registry,
    required this.ptyLibrary,
    DateTime Function()? clock,
    this.hostVersion = kHostVersion,
    this.companion,
    this.build,
    this.mcpTools,
    this.automations,
    HookHolds? holds,
  }) : _now = clock ?? _utcNow,
       startedAt = (clock ?? _utcNow)(),
       lifecycle = LifecycleFeed(
         registry,
         clock: clock ?? _utcNow,
         holds: holds,
       );

  final SessionRegistry registry;
  final LifecycleFeed lifecycle;
  final String ptyLibrary;

  /// The phone companion: pairing windows, the app's Remote access settings,
  /// and the calls forwarded to the app.
  ///
  /// Injected rather than built here, because it needs a store and listeners
  /// and this class needs neither — and a `serve` that was started without a
  /// store must refuse rather than pretend. Null is that refusal.
  final CompanionHandler? companion;
  final String hostVersion;

  /// Where agents' tool calls go to the app that runs them; null serves none.
  final McpToolRelay? mcpTools;

  /// The daemon's automations and checks; null when there is no store. Set
  /// after construction, because it needs this server's lifecycle feed.
  AutomationHandler? automations;

  /// Answers the prompts of the agents this host holds; null when there is no
  /// store to keep their status by. Set after construction, like
  /// [automations].
  DaemonPromptAnswers? prompts;

  /// Answers `serverCall` — devices, revoke, agents; null refuses each with
  /// the reason (no store).
  ServerAdmin? admin;

  /// This executable's `hostBuildOf`, read once at start, so a binary
  /// replaced under a running `serve` still reports the build it runs.
  final String? build;
  final DateTime Function() _now;
  final DateTime startedAt;

  /// UTC everywhere on the wire: the host and the app are often in different
  /// zones, and a timestamp needing one is a reading nobody can compare.
  static DateTime _utcNow() => DateTime.now().toUtc();

  final _clients = <_ClientSession>[];
  int get clientCount => _clients.length;

  /// Serves one connection until the peer goes away, then releases that
  /// client's tokens and kills nothing.
  Future<void> serveConnection(HostConnection connection) async {
    final client = _ClientSession(this, connection);
    _clients.add(client);
    try {
      await client.run();
    } finally {
      _clients.remove(client);
    }
  }

  StreamSubscription<HostConnection> listen(HostListener listener) => listener
      .connections
      .listen((connection) => unawaited(serveConnection(connection)));

  DateTime now() => _now();
}

/// One connected client: its id, its session refs, its subscriptions.
class _ClientSession {
  _ClientSession(this._server, this._connection);

  final HostServer _server;
  final HostConnection _connection;

  String _clientId = '';
  var _greeted = false;
  var _refs = 0;
  final _byRef = <int, HostSession>{};
  final _subscriptions = <int, StreamSubscription<OutputChunk>>{};
  final _exitWatches = <int, StreamSubscription<void>>{};
  StreamSubscription<HostMessage>? _lifecycleWatch;

  Future<void> run() async {
    final parser = FrameParser();
    try {
      await for (final chunk in _connection.incoming) {
        final List<Frame> frames;
        try {
          frames = parser.add(chunk);
        } on FrameFormatException catch (e) {
          // Resynchronising onto garbage is worse than hanging up.
          _send(ErrorMessage(0, ProtocolErrorCode.badRequest, e.message));
          break;
        }
        for (final frame in frames) {
          await _handle(frame);
          if (_hungUp) break;
        }
        if (_hungUp) break;
      }
    } on SocketException {
      // A peer that vanished is the ordinary case, not a fault.
    } finally {
      await _cleanUp();
    }
  }

  var _hungUp = false;

  Future<void> _cleanUp() async {
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    for (final subscription in _exitWatches.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _exitWatches.clear();
    await _lifecycleWatch?.cancel();
    _server.mcpTools?.detach(this);
    _server.automations?.detach(this);
    await _server.companion?.detach(this);
    // A disconnect frees the write token and leaves every session running.
    if (_clientId.isNotEmpty) _server.registry.forgetClient(_clientId);
    await _connection.close();
  }

  /// Held back while a flush is in flight: dart:io refuses `add` then with the
  /// same StateError a closed sink throws, and dropping the frame lost exits.
  final _heldWhileFlushing = <Uint8List>[];
  final _pausedForFlush = <StreamSubscription<OutputChunk>>{};
  var _flushing = false;
  var _sentSinceFlush = 0;

  void _send(HostMessage message) => _sendBytes(message.toFrame().encode());

  void _sendBytes(Uint8List bytes) {
    if (_hungUp) return;
    if (_flushing) {
      _heldWhileFlushing.add(bytes);
      return;
    }
    try {
      _connection.add(bytes);
    } on StateError {
      _hungUp = true; // the sink is closed under us
    }
  }

  /// Counted, not timed: a slow link stalls its own pumps rather than growing
  /// an unbounded queue in this process.
  void _paceOutput(StreamSubscription<OutputChunk> subscription) {
    if (++_sentSinceFlush < 8 || _hungUp) return;
    subscription.pause();
    _pausedForFlush.add(subscription);
    if (_flushing) return;
    _flushing = true;
    _connection.flush().then(
      (_) => _flushed(),
      onError: (Object _) => _peerGone(),
    );
  }

  void _flushed() {
    _flushing = false;
    _sentSinceFlush = 0;
    final held = List.of(_heldWhileFlushing);
    _heldWhileFlushing.clear();
    for (final bytes in held) {
      _sendBytes(bytes);
    }
    final paused = List.of(_pausedForFlush);
    _pausedForFlush.clear();
    if (_hungUp) return;
    for (final subscription in paused) {
      if (subscription.isPaused) subscription.resume();
    }
  }

  /// A flush that fails is the peer gone, not a fault of this process; the
  /// pumps stay paused until [_cleanUp] cancels them.
  void _peerGone() {
    _flushing = false;
    _hungUp = true;
    _heldWhileFlushing.clear();
  }

  /// Whatever one frame does to this client, it does to this client only: an
  /// escape here would reach `unawaited(serveConnection)` and end the host.
  Future<void> _handle(Frame frame) async {
    try {
      await _dispatch(frame);
    } on FormatException catch (e) {
      // WireReader.str decodes UTF-8 strictly, and that is a bad request too.
      _send(ErrorMessage(0, ProtocolErrorCode.badRequest, e.message));
      _hungUp = true;
    } on Object catch (e) {
      _send(
        ErrorMessage(
          0,
          ProtocolErrorCode.internal,
          '${frame.type.name} failed: $e',
        ),
      );
      _hungUp = true;
    }
  }

  Future<void> _dispatch(Frame frame) async {
    final HostMessage message;
    try {
      message = decodeMessage(frame);
    } on WireFormatException catch (e) {
      _send(ErrorMessage(0, ProtocolErrorCode.badRequest, e.message));
      _hungUp = true;
      return;
    }

    if (!_greeted && message is! HelloMessage) {
      _send(
        ErrorMessage(
          0,
          ProtocolErrorCode.helloRequired,
          'the first frame must be hello; got ${frame.type.name}',
        ),
      );
      _hungUp = true;
      return;
    }

    switch (message) {
      case HelloMessage():
        _onHello(message);
      case ListMessage():
        _send(SessionsMessage(message.requestId, _server.registry.list()));
      case OpenMessage():
        _onOpen(message);
      case AttachMessage():
        _onAttach(message);
      case InputMessage():
        _onInput(message);
      case ResizeMessage():
        _onResize(message);
      case ClaimMessage():
        _onClaim(message);
      case ReleaseMessage():
        _onRelease(message);
      case CloseMessage():
        await _onClose(message);
      case PairMessage():
        await _onPair(message);
      case WatchMessage():
        await _lifecycleWatch?.cancel();
        _lifecycleWatch = _server.lifecycle.watch(
          message.requestId,
          _send,
          runByClient: message.runByClient,
        );
      case HookReplyMessage():
        _server.lifecycle.replyHook(message.holdId);
      case McpToolsMessage():
        _server.mcpTools?.adopt(this, message.tools, _send);
      case McpResultMessage():
        _server.mcpTools?.answer(this, message);
      case CompanionAttachMessage(:final localRelayUrl):
        await _server.companion?.adopt(
          this,
          localRelayUrl == null ? null : Uri.tryParse(localRelayUrl),
          _send,
        );
      case CompanionResultMessage():
        _server.companion?.answer(this, message);
      case CompanionNoticeMessage():
        await _server.companion?.notice(this, message);
      case AutomationNoticeMessage():
        _server.automations?.notice(this, message, _send);
      case AutomationResultMessage():
        _server.automations?.answer(this, message);
      case ChecksRunMessage():
        _onChecksRun(message);
      case PromptAnswerMessage():
        _onPromptAnswer(message);
      case ServerCallMessage():
        _onServerCall(message);
      default:
        _send(
          ErrorMessage(
            0,
            ProtocolErrorCode.badRequest,
            '${frame.type.name} is a host-to-client message',
          ),
        );
    }
  }

  /// Not awaited: an answer reads the screen back between keys, and this
  /// client's other frames must not wait behind it.
  void _onPromptAnswer(PromptAnswerMessage message) {
    final prompts = _server.prompts;
    if (prompts == null) {
      _send(
        PromptAnsweredMessage.refused(
          requestId: message.requestId,
          refusal: PromptRefusalKind.refused,
          message: 'this host keeps no agent status: it has no store',
        ),
      );
      return;
    }
    unawaited(
      prompts.answerFrame(message.requestId, message.request).then(_send),
    );
  }

  /// Not awaited: an agent probe runs processes, and this client's other
  /// frames must not wait behind it.
  void _onServerCall(ServerCallMessage message) {
    final admin = _server.admin;
    if (admin == null) {
      _send(
        ServerResultMessage.failure(
          message.requestId,
          'this host keeps no devices or agents: it has no store',
        ),
      );
      return;
    }
    unawaited(
      admin
          .call(message.method, message.arguments)
          .then(
            (result) =>
                _send(ServerResultMessage.success(message.requestId, result)),
            onError: (Object error) => _send(
              ServerResultMessage.failure(
                message.requestId,
                error is ServerCallRefused
                    ? error.message
                    : '${message.method} failed: $error',
              ),
            ),
          ),
    );
  }

  /// Not awaited: a test suite takes minutes, and this client's other frames
  /// must not wait behind it.
  void _onChecksRun(ChecksRunMessage message) {
    final automations = _server.automations;
    if (automations == null) {
      _send(
        ChecksRanMessage(
          requestId: message.requestId,
          outcome: ChecksRunOutcome.elsewhere,
          message: 'this host runs no automations: it has no store',
        ),
      );
      return;
    }
    unawaited(automations.runChecks(message).then(_send));
  }

  Future<void> _onPair(PairMessage message) async {
    final companion = _server.companion;
    if (companion == null) {
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.badRequest,
          'this host is serving sessions but cannot pair: it was started '
          'without a store to keep a pairing in',
        ),
      );
      return;
    }
    try {
      final window = await companion.openPairing(
        capabilities: message.capabilities,
        relay: message.relay,
        relayIsLocal: message.relayIsLocal,
        label: message.label,
      );
      _send(
        PairedMessage(
          requestId: message.requestId,
          code: window.code,
          expiresAt: window.expiresAt,
          payload: window.payload,
        ),
      );
      // Told to whoever asked, if they are still here: the desktop's dialog
      // waits on it, and `pair` over SSH has long since hung up.
      unawaited(
        window.paired.then(
          (deviceId) => _send(
            CompanionEventMessage(
              CompanionEventKind.pairingEnded,
              requestId: message.requestId,
              deviceId: deviceId,
            ),
          ),
          onError: (Object error) => _send(
            CompanionEventMessage(
              CompanionEventKind.pairingEnded,
              requestId: message.requestId,
              error: _pairingError(error),
            ),
          ),
        ),
      );
    } on Object catch (error) {
      // Named, not swallowed: a person is waiting to type a code, and "nothing
      // happened" is the one answer that leaves them with nothing to do.
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.internal,
          'could not open a pairing window: $error',
        ),
      );
    }
  }

  static String _pairingError(Object error) {
    final text = '$error';
    const prefix = 'PairingException: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }

  void _onHello(HelloMessage message) {
    if (message.protocolVersion != kProtocolVersion) {
      // On the first exchange: a skewed client that keeps talking corrupts a
      // pane in a way nobody traces back to a version.
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.protocolMismatch,
          'host speaks protocol $kProtocolVersion, client speaks ${message.protocolVersion}',
        ),
      );
      _hungUp = true;
      return;
    }
    _greeted = true;
    _clientId = message.clientId.isEmpty
        ? _connection.description
        : message.clientId;
    _send(
      WelcomeMessage(
        requestId: message.requestId,
        protocolVersion: kProtocolVersion,
        hostVersion: _server.hostVersion,
        operatingSystem: Platform.operatingSystem,
        architecture: _architecture(),
        ptyLibrary: _server.ptyLibrary,
        pid: pid,
        startedAt: _server.startedAt,
        observedAt: _server.now(),
        build: _server.build,
      ),
    );
  }

  void _onOpen(OpenMessage message) {
    try {
      _server.registry.open(
        message.sessionId,
        PtySpawnRequest(
          argv: message.argv,
          workingDirectory: message.workingDirectory,
          environment: message.environment,
          removedEnvironment: message.removedEnvironment,
          columns: message.columns,
          rows: message.rows,
        ),
      );
    } on SessionAlreadyExists catch (e) {
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.sessionExists,
          e.toString(),
        ),
      );
      return;
    } on PtyException catch (e) {
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.spawnFailed,
          e.toString(),
        ),
      );
      return;
    }
    // Opening implies attaching from nothing, with the write token.
    _onAttach(
      AttachMessage(
        requestId: message.requestId,
        sessionId: message.sessionId,
        sinceOffset: 0,
        claimWrite: true,
      ),
    );
  }

  void _onAttach(AttachMessage message) {
    final HostSession session;
    try {
      session = _server.registry.require(message.sessionId);
    } on UnknownSession catch (e) {
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.unknownSession,
          e.toString(),
        ),
      );
      return;
    }
    final now = _server.now();
    final ref = ++_refs;
    _byRef[ref] = session;

    String? holder = session.token.holder?.clientId;
    if (message.claimWrite) {
      final refusal = session.token.claim(_clientId, now);
      holder = refusal?.holder?.clientId ?? _clientId;
    }

    // A pane asking for the screen gets it at its own grid: the session is
    // taken there first, so the snapshot is drawn at the width the pane will
    // show it at, and the program's redraw for that size follows as output.
    final grid = message.screenGrid;
    if (grid != null &&
        session.token.isHeldBy(_clientId) &&
        (grid.$1 != session.columns || grid.$2 != session.rows)) {
      session.resize(_clientId, grid.$1, grid.$2, now);
    }
    final screen = grid == null ? null : session.snapshot();

    // Measured before the pump starts, so the numbers told are the numbers sent.
    final slice = session.backlog.since(message.sinceOffset);
    final from = screen?.$2 ?? message.sinceOffset;
    _send(
      AttachedMessage(
        requestId: message.requestId,
        sessionRef: ref,
        sessionId: session.id,
        columns: session.columns,
        rows: session.rows,
        replayFromOffset: screen?.$2 ?? slice.offset,
        droppedBytes: screen == null ? slice.droppedBytes : 0,
        totalBytes: session.backlog.totalBytes,
        holdsWriteToken: session.token.isHeldBy(_clientId),
        writeHolder: holder,
        observedAt: now,
        screenFollows: screen != null,
      ),
    );
    if (screen != null) {
      _send(ScreenMessage(ref, screen.$2, utf8.encode(screen.$1)));
    }

    late final StreamSubscription<OutputChunk> subscription;
    subscription = session.readFrom(from).listen((chunk) {
      _send(OutputMessage(ref, chunk.offset, chunk.bytes));
      _paceOutput(subscription);
    });
    _subscriptions[ref] = subscription;

    if (session.lifecycle.hasEnded) {
      _sendExit(ref, session);
    } else {
      _exitWatches[ref] = session.ended.asStream().listen(
        (_) => _sendExit(ref, session),
      );
    }
  }

  void _sendExit(int ref, HostSession session) {
    final lifecycle = session.lifecycle;
    _send(
      ExitedMessage(
        sessionRef: ref,
        sessionId: session.id,
        exitCode: lifecycle.exitCode,
        reason: lifecycle.describe(),
        observedAt: _server.now(),
      ),
    );
  }

  void _onInput(InputMessage message) {
    final session = _byRef[message.sessionRef];
    if (session == null) return _sendUnknownRef(message.sessionRef);
    final refusal = session.write(_clientId, message.bytes, _server.now());
    if (refusal != null) {
      _send(ErrorMessage(0, ProtocolErrorCode.writeRefused, refusal.message));
    }
  }

  void _onResize(ResizeMessage message) {
    final session = _byRef[message.sessionRef];
    if (session == null) return _sendUnknownRef(message.sessionRef);
    final refusal = session.resize(
      _clientId,
      message.columns,
      message.rows,
      _server.now(),
    );
    if (refusal != null) {
      _send(ErrorMessage(0, ProtocolErrorCode.writeRefused, refusal.message));
    }
  }

  void _onClaim(ClaimMessage message) {
    final session = _byRef[message.sessionRef];
    if (session == null) return _sendUnknownRef(message.sessionRef);
    final refusal = session.token.claim(_clientId, _server.now());
    if (refusal != null) {
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.writeRefused,
          refusal.message,
        ),
      );
      return;
    }
    _send(
      ClaimedMessage(
        requestId: message.requestId,
        sessionRef: message.sessionRef,
        holdsWriteToken: true,
        writeHolder: _clientId,
      ),
    );
  }

  void _onRelease(ReleaseMessage message) {
    final session = _byRef[message.sessionRef];
    if (session == null) return _sendUnknownRef(message.sessionRef);
    session.token.release(_clientId);
    _send(
      ClaimedMessage(
        requestId: message.requestId,
        sessionRef: message.sessionRef,
        holdsWriteToken: false,
        writeHolder: session.token.holder?.clientId,
      ),
    );
  }

  Future<void> _onClose(CloseMessage message) async {
    final SessionLifecycle end;
    try {
      end = await _server.registry.close(
        message.sessionId,
        signal: message.signal,
      );
    } on UnknownSession catch (e) {
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.unknownSession,
          e.toString(),
        ),
      );
      return;
    }
    _send(ClosedMessage(message.requestId, message.sessionId, end.exitCode));
  }

  void _sendUnknownRef(int ref) => _send(
    ErrorMessage(
      0,
      ProtocolErrorCode.unknownSession,
      'no session attached at ref $ref',
    ),
  );
}

String _architecture() {
  final match = RegExp(r'"[a-z]+_([a-z0-9]+)"').firstMatch(Platform.version);
  return match?.group(1) ?? 'unknown';
}
