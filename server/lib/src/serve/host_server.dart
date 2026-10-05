import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataEnvelope, DataRefused, DataStreamEnvelope, DataStreamItems;

import '../companion/companion_handler.dart';
import '../data/data_service.dart';
import '../data/data_streams.dart';
import '../domain/host_session.dart';
import 'package:karmashala_host_protocol/protocol.dart';
import 'package:karmashala_remote/remote.dart' show Capability;
import '../domain/session_registry.dart';
import '../domain/write_token.dart';
import '../pty/pty.dart';
import '../server/server_admin.dart';
import '../ssh/ssh_domain.dart'
    show BoxRelay, BoxRelayClient, BoxRelayPeer;
import '../status/daemon_prompt_answers.dart';
import '../transport/link_trust.dart';
import '../transport/transport.dart';
import 'lifecycle_feed.dart';
import 'server_features.dart';

/// The most one ref's output may run ahead of what its client acknowledged
/// (slice 5e); past it the pump stops, and resumes from the ring — or from
/// the screen, once the ring has moved on.
const int kUnackedOutputBytes = 512 * 1024;

/// The largest output frame: a replay of the whole ring is sent in pieces,
/// so one pane's history never holds a link for megabytes.
const int kOutputChunkBytes = 64 * 1024;

/// Serves the protocol to whoever connects, over whatever carried them. It
/// knows nothing about SSH transport (see transport.dart); a session on an
/// SSH box is relayed through [boxes] (slice 5d), frame by frame, by ref.
class HostServer {
  HostServer({
    required this.registry,
    required this.ptyLibrary,
    DateTime Function()? clock,
    this.hostVersion = kHostVersion,
    this.companion,
    this.build,
  }) : _now = clock ?? _utcNow,
       startedAt = (clock ?? _utcNow)(),
       lifecycle = LifecycleFeed(registry, clock: clock ?? _utcNow);

  final SessionRegistry registry;
  final LifecycleFeed lifecycle;
  final String ptyLibrary;

  /// The phone companion: the pairing windows a client opens and closes.
  ///
  /// Injected rather than built here, because it needs a store and listeners
  /// and this class needs neither — and a `serve` that was started without a
  /// store must refuse rather than pretend. Null is that refusal.
  final CompanionHandler? companion;
  final String hostVersion;

  /// Answers the prompts of the agents this host holds; null when there is no
  /// store to keep their status by. Set after construction.
  DaemonPromptAnswers? prompts;

  /// Answers `serverCall` — devices, revoke, agents; null refuses each with
  /// the reason (no store).
  ServerAdmin? admin;

  /// Answers every client's data requests; null refuses them (no store).
  DataService? data;

  /// Begins `serve`'s own shutdown, for `stopNow`; null refuses it.
  void Function()? onStopRequested;

  /// The SSH boxes this server reaches (slice 5d): a client attaching to a
  /// session there is relayed through them. Null reaches none.
  BoxRelay? boxes;

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
  /// client's tokens and kills nothing. [trust] is what the link may do: all
  /// of it over this machine's socket, what its pairing grants over the
  /// companion's sealed channel (slice 5e).
  Future<void> serveConnection(
    HostConnection connection, {
    LinkTrust trust = LinkTrust.local,
  }) async {
    final client = _ClientSession(this, connection, trust);
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

  /// Every client attachment to each of this server's sessions, by id.
  final _attachments = <String, Set<(_ClientSession, int)>>{};

  /// Whose grid each session is at, by id: the last holder that sized it.
  final _sizedFor = <String, String>{};

  /// Whose grid each session was at before its sizer took it, and that grid:
  /// where it goes back to when the sizer lets go.
  final _sizedBefore = <String, (String?, int, int)>{};

  /// Whom each session's token was last taken from.
  final _takenFrom = <String, String>{};

  /// Marks [session] as at [clientId]'s grid; call before resizing it.
  void _sizedBy(HostSession session, String clientId) {
    final was = _sizedFor[session.id];
    if (was == clientId) return;
    _sizedBefore[session.id] = (
      was ?? _takenFrom[session.id],
      session.columns,
      session.rows,
    );
    _sizedFor[session.id] = clientId;
  }

  /// [clientId] let go of [session]: if it was sized for that client, it goes
  /// back to the grid of the one it was taken from, while that one is here.
  void _giveBackSize(HostSession session, String clientId) {
    if (_sizedFor[session.id] != clientId) return;
    final before = _sizedBefore.remove(session.id);
    if (before == null) return;
    final (owner, columns, rows) = before;
    if (owner == null) return;
    (int, int)? wanted;
    var here = false;
    for (final (client, ref) in _attachments[session.id] ?? const <Never>{}) {
      if (client._clientId != owner) continue;
      here = true;
      wanted ??= client._flows[ref]?.wantedGrid;
    }
    if (!here) return;
    final (c, r) = wanted ?? (columns, rows);
    if (c != session.columns || r != session.rows) session.resizeAsHost(c, r);
    _sizedFor[session.id] = owner;
    _presenceChanged(session);
  }

  void _attached(HostSession session, _ClientSession client, int ref) {
    (_attachments[session.id] ??= {}).add((client, ref));
    _presenceChanged(session);
  }

  void _detached(HostSession session, _ClientSession client, int ref) {
    final set = _attachments[session.id];
    if (set == null) return;
    set.remove((client, ref));
    if (set.isEmpty) _attachments.remove(session.id);
    if (!set.any((attachment) => identical(attachment.$1, client))) {
      _giveBackSize(session, client._clientId);
    }
    _presenceChanged(session);
  }

  /// A client's id, made unique among those connected: the token and
  /// presence name clients by it, and two windows are two clients.
  String _uniqueId(String wanted, _ClientSession self) {
    bool taken(String id) =>
        _clients.any((c) => !identical(c, self) && c._clientId == id);
    if (!taken(wanted)) return wanted;
    for (var n = 2; ; n++) {
      final next = '$wanted ($n)';
      if (!taken(next)) return next;
    }
  }

  /// Tells every client attached to [session] who drives it and who watches.
  void _presenceChanged(HostSession session) {
    final set = _attachments[session.id];
    if (set == null || set.isEmpty) return;
    final holder = session.token.holder?.clientId;
    final viewers = <String>{
      for (final (client, _) in set)
        if (client._clientId != holder) client._clientId,
    }.toList();
    for (final (client, ref) in set) {
      client._send(
        PresenceMessage(
          sessionRef: ref,
          holder: holder,
          viewers: viewers,
          sizedFor: _sizedFor[session.id],
          columns: session.columns,
          rows: session.rows,
        ),
      );
    }
  }
}

/// One ref's output as sent to a client that acknowledges it.
class _Flow {
  _Flow(this.session, this.sent) : acked = sent;

  final HostSession session;
  int sent;
  int acked;
  StreamSubscription<OutputChunk>? subscription;
  StreamSubscription<void>? exitWatch;
  var stalled = false;
  var exitPending = false;

  /// Whether this ref claims the session: at attach or by a claim. Only then
  /// is a resize it sends meanwhile kept for when it takes the input.
  var claims = false;

  /// The grid this client last asked for, kept while it could not apply it:
  /// a claim takes the session there.
  (int, int)? wantedGrid;
}

/// One connected client: its id, its session refs, its subscriptions.
class _ClientSession implements BoxRelayPeer {
  _ClientSession(this._server, this._connection, this._trust);

  final HostServer _server;
  final HostConnection _connection;
  final LinkTrust _trust;

  String _clientId = '';
  var _greeted = false;
  var _acks = false;
  var _refs = 0;
  final _flows = <int, _Flow>{};

  /// This client's attachments to SSH box sessions (slice 5d), relayed by
  /// the ssh domain; made on the first one.
  BoxRelayClient? _relay;
  BoxRelayClient get _boxes => _relay ??= _server.boxes!.clientFor(this);

  /// Whether [ref] is relayed from a box.
  bool _relays(int ref) => _relay?.holds(ref) ?? false;

  /// Whether [sessionId] is a box's rather than this server's own.
  bool _onBox(String sessionId) =>
      _server.registry.find(sessionId) == null &&
      (_server.boxes?.relays(sessionId) ?? false);

  @override
  String get clientId => _clientId;

  @override
  bool get hungUp => _hungUp;

  @override
  int nextRef() => ++_refs;

  @override
  DateTime now() => _server.now();

  @override
  void send(HostMessage message) => _send(message);

  @override
  void pace(StreamSubscription<Object?> subscription) =>
      _paceOutput(subscription);

  @override
  void hangUp() {
    if (_hungUp) return;
    _hungUp = true;
    unawaited(_connection.close());
  }

  StreamSubscription<HostMessage>? _lifecycleWatch;
  DataSession? _data;
  DataStreamSession? _streams;

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
    final flows = Map.of(_flows);
    _flows.clear();
    for (final flow in flows.values) {
      await flow.subscription?.cancel();
      await flow.exitWatch?.cancel();
    }
    // Only a client with box attachments waits on them: every other hangs
    // up exactly as before.
    final relay = _relay;
    if (relay != null) await relay.dispose();
    _data?.close();
    _streams?.closeAll();
    await _lifecycleWatch?.cancel();
    // A disconnect frees the write token and leaves every session running.
    if (_clientId.isNotEmpty) _server.registry.forgetClient(_clientId);
    for (final entry in flows.entries) {
      _server._detached(entry.value.session, this, entry.key);
    }
    await _connection.close();
  }

  /// Held back while a flush is in flight: dart:io refuses `add` then with the
  /// same StateError a closed sink throws, and dropping the frame lost exits.
  final _heldWhileFlushing = <Uint8List>[];
  final _pausedForFlush = <StreamSubscription<Object?>>{};
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
  void _paceOutput(StreamSubscription<Object?> subscription) {
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

    // Before hello and whatever the client's protocol: a `stop` from any
    // version must be able to ask.
    if (message is StopCheckMessage || message is StopNowMessage) {
      final requestId = switch (message) {
        StopCheckMessage(:final requestId) => requestId,
        StopNowMessage(:final requestId) => requestId,
        _ => 0,
      };
      final stopping = message is StopNowMessage;
      if (_trust.remote) {
        _send(
          const ErrorMessage(
            0,
            ProtocolErrorCode.badRequest,
            'stop is asked on the server\'s own machine, not over a remote '
            'link',
          ),
        );
        _hungUp = true;
        return;
      }
      final stop = _server.onStopRequested;
      if (stopping && stop == null) {
        _send(
          const ErrorMessage(
            0,
            ProtocolErrorCode.badRequest,
            'this host cannot be asked to stop',
          ),
        );
        _hungUp = true;
        return;
      }
      _send(
        StopCheckAnswerMessage(
          requestId: requestId,
          protocolVersion: kProtocolVersion,
          pid: pid,
          runningSessions: _server.registry
              .list()
              .where((s) => !s.lifecycle.hasEnded)
              .length,
        ),
      );
      _hungUp = true;
      if (stopping) stop!();
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

    if (_trust.remote && _refusedRemotely(message)) return;

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
      case DetachMessage(:final sessionRef):
        await _onDetach(sessionRef);
      case OutputAckMessage():
        _onOutputAck(message);
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
      case CompanionNoticeMessage():
        await _server.companion?.notice(this, message);
      case PromptAnswerMessage():
        _onPromptAnswer(message);
      case ServerCallMessage():
        _onServerCall(message);
      case DataStreamOpenMessage(:final envelope):
        _onDataStreamOpen(envelope);
      case DataStreamCloseMessage(:final envelope):
        _streams?.closeJson(envelope);
      case DataRequestMessage():
        _onDataRequest(message);
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

  /// What a client on another machine may not ask (slice 5e), refused in
  /// words: it pairs nothing, closes no pairing window, spawns no argv of its
  /// own, and administers the server only when its pairing grants it.
  bool _refusedRemotely(HostMessage message) {
    String? refusal;
    var requestId = 0;
    switch (message) {
      case PairMessage():
        requestId = message.requestId;
        refusal = 'pairing is opened on the server\'s own machine, not over '
            'a remote link';
      case CompanionNoticeMessage():
        return true;
      case OpenMessage():
        requestId = message.requestId;
        refusal = 'a client on another machine opens terminals through the '
            'server (terminals.open), not by argv';
      case ServerCallMessage() when !_trust.admin:
        _send(
          ServerResultMessage.failure(
            message.requestId,
            'this client may not administer the server: its pairing does not '
            'grant it',
          ),
        );
        return true;
      default:
        return false;
    }
    _send(ErrorMessage(requestId, ProtocolErrorCode.badRequest, refusal));
    return true;
  }

  /// Not awaited: an answer reads the screen back between keys, and this
  /// client's other frames must not wait behind it.
  void _onPromptAnswer(PromptAnswerMessage message) {
    if (!_trust.may(Capability.approve)) {
      _send(
        PromptAnsweredMessage.refused(
          requestId: message.requestId,
          refusal: PromptRefusalKind.refused,
          message: 'this device was not granted ${Capability.approve.wire}',
        ),
      );
      return;
    }
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

  /// Answered in order, at once: the store is synchronous, and a client's
  /// writes must land in the order it sent them. The one exception reads the
  /// disk and writes nothing a client copies (`conversations.catchUp`): it is
  /// answered when done, by its id.
  void _onDataRequest(DataRequestMessage message) {
    final service = _server.data;
    if (service == null) {
      _send(
        DataAnswerMessage(
          DataEnvelope.refusal(
            DataEnvelope.answerId(message.envelope) ?? 0,
            const DataRefused.unavailable('this host keeps no data: no store'),
          ),
        ),
      );
      return;
    }
    final session = _data ??= service.open(
      (changes) => _send(DataChangesMessage(DataEnvelope.changes(changes))),
      admin: _trust.admin,
      sshPrompts: _trust.sshPrompts,
      transcripts: _trust.transcripts,
      phone: _trust.phone,
      grants: _trust.grants,
      device: _trust.deviceId,
    );
    final answer = session.handleJson(message.envelope);
    if (answer is Future<Map<String, Object?>>) {
      unawaited(answer.then((later) => _send(DataAnswerMessage(later))));
    } else {
      _send(DataAnswerMessage(answer));
    }
  }

  /// A live stream (a Flutter app's console) on this link, batched and
  /// bounded by [DataStreamSession]. With no data service there is nothing
  /// to follow: the stream is ended at once.
  void _onDataStreamOpen(Map<String, Object?> envelope) {
    final service = _server.data;
    if (service == null) {
      final read = DataStreamEnvelope.readOpen(envelope);
      if (read == null) return;
      _send(
        DataStreamItemsMessage(
          DataStreamEnvelope.items(
            DataStreamItems(
              read.streamId,
              const [],
              ended: 'this host keeps no data: no store',
            ),
          ),
        ),
      );
      return;
    }
    final streams = _streams ??= DataStreamSession(
      service.streamSources,
      (batch) => _send(DataStreamItemsMessage(DataStreamEnvelope.items(batch))),
    );
    streams.open(envelope);
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
    _acks = message.ackingOutput;
    _clientId = _server._uniqueId(
      message.clientId.isNotEmpty
          ? message.clientId
          : _trust.label ?? _connection.description,
      this,
    );
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
        features: kServerFeatures,
      ),
    );
  }

  void _onOpen(OpenMessage message) {
    if (parseBoxSessionRef(message.sessionId) != null) {
      // A box's session is started by the server (`terminals.open`), which
      // builds its launch for the box; a raw open would name nothing there.
      _send(
        ErrorMessage(
          message.requestId,
          ProtocolErrorCode.badRequest,
          'a session on an SSH box is opened through the server '
          '(terminals.open), not by id',
        ),
      );
      return;
    }
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
      if (_onBox(message.sessionId)) {
        _boxes.attach(message);
        return;
      }
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

    String? holder = session.token.holder?.clientId;
    if (message.claimWrite) {
      final refusal = session.token.claim(_clientId, now);
      holder = refusal?.holder?.clientId ?? _clientId;
    }

    // A pane asking for the screen gets it at its own grid: the session is
    // taken there first, so the snapshot is drawn at the width the pane will
    // show it at, and the program's redraw for that size follows as output.
    // Only a claiming pane: an unclaimed one (a phone) must never resize by
    // looking, even from a client still holding the input.
    final grid = message.screenGrid;
    if (grid != null &&
        message.claimWrite &&
        session.token.isHeldBy(_clientId) &&
        (grid.$1 != session.columns || grid.$2 != session.rows)) {
      _server._sizedBy(session, _clientId);
      session.resize(_clientId, grid.$1, grid.$2, now);
    }
    final screen = grid == null ? null : session.snapshot();

    // Measured before the pump starts, so the numbers told are the numbers sent.
    final slice = session.backlog.since(message.sinceOffset);
    final from = screen?.$2 ?? slice.offset;
    _send(
      AttachedMessage(
        requestId: message.requestId,
        sessionRef: ref,
        sessionId: session.id,
        columns: session.columns,
        rows: session.rows,
        replayFromOffset: from,
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

    // No wish for an unclaimed pane: its keystroke leaves the grid alone.
    final flow = _Flow(session, from)
      ..claims = message.claimWrite
      ..wantedGrid = message.claimWrite ? grid : null;
    _flows[ref] = flow;
    _server._attached(session, this, ref);
    _pump(ref, flow, from);

    if (session.lifecycle.hasEnded) {
      _exitWhenDrained(ref, flow);
    } else {
      flow.exitWatch = session.ended.asStream().listen(
        (_) => _exitWhenDrained(ref, flow),
      );
    }
  }

  /// Streams [flow]'s output from [from] in pieces of at most
  /// [kOutputChunkBytes]; for a client that acknowledges, stops once
  /// [kUnackedOutputBytes] are out unacknowledged.
  void _pump(int ref, _Flow flow, int from) {
    late final StreamSubscription<OutputChunk> subscription;
    subscription = flow.session.readFrom(from).listen(
      (chunk) {
        if (flow.stalled) return;
        var at = chunk.offset < flow.sent ? flow.sent : chunk.offset;
        while (at < chunk.nextOffset) {
          if (_acks && at - flow.acked >= kUnackedOutputBytes) {
            flow.stalled = true;
            unawaited(subscription.cancel());
            return;
          }
          final end = at + kOutputChunkBytes < chunk.nextOffset
              ? at + kOutputChunkBytes
              : chunk.nextOffset;
          _send(
            OutputMessage(
              ref,
              at,
              Uint8List.sublistView(
                chunk.bytes,
                at - chunk.offset,
                end - chunk.offset,
              ),
            ),
          );
          at = end;
          flow.sent = end;
        }
        _paceOutput(subscription);
      },
      onDone: () {
        if (!flow.stalled && flow.exitPending) _sendExit(ref, flow.session);
      },
    );
    flow.subscription = subscription;
  }

  /// A client that caught up is sent the rest from the ring — or, when the
  /// ring has moved past what it last saw, the screen again: never a gap.
  void _onOutputAck(OutputAckMessage message) {
    final flow = _flows[message.sessionRef];
    if (flow == null) return;
    if (message.offset > flow.acked) flow.acked = message.offset;
    if (!flow.stalled || flow.sent - flow.acked > kUnackedOutputBytes ~/ 2) {
      return;
    }
    flow.stalled = false;
    final session = flow.session;
    var from = flow.sent;
    if (session.backlog.firstAvailableOffset > from) {
      final screen = session.snapshot();
      if (screen != null) {
        _send(
          ScreenMessage(message.sessionRef, screen.$2, utf8.encode(screen.$1)),
        );
        from = screen.$2;
      } else {
        from = session.backlog.firstAvailableOffset;
      }
      flow.sent = from;
      flow.acked = from;
    }
    _pump(message.sessionRef, flow, from);
  }

  /// The exit follows the last byte this client is sent, not the process.
  void _exitWhenDrained(int ref, _Flow flow) {
    if (flow.stalled || flow.sent < flow.session.backlog.totalBytes) {
      flow.exitPending = true;
      return;
    }
    _sendExit(ref, flow.session);
  }

  void _sendExit(int ref, HostSession session) {
    final flow = _flows[ref];
    if (flow == null) return;
    flow.exitPending = false;
    final lifecycle = session.lifecycle;
    if (!lifecycle.hasEnded) return;
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

  /// A keystroke from a client that does not hold the token takes it when
  /// its holder has been idle past [WriteToken.idleBeforeTakeover] (or
  /// nobody holds it); otherwise it is refused on its ref, and the pane
  /// offers "Take over" from the presence it was told.
  void _onInput(InputMessage message) {
    if (_relays(message.sessionRef)) return _boxes.input(message);
    final flow = _flows[message.sessionRef];
    if (flow == null) return _sendUnknownRef(message.sessionRef);
    final session = flow.session;
    final now = _server.now();
    if (!session.token.isHeldBy(_clientId) &&
        session.token.yieldsTo(_clientId, now)) {
      _takeToken(flow, now);
    }
    final refusal = session.write(_clientId, message.bytes, now);
    if (refusal != null) {
      _send(
        ErrorMessage(
          0,
          ProtocolErrorCode.writeRefused,
          refusal.message,
          sessionRef: message.sessionRef,
        ),
      );
    }
  }

  /// Hands the token to this client and the session to its grid.
  void _takeToken(_Flow flow, DateTime now) {
    final session = flow.session;
    final token = session.token;
    final from = token.holder?.clientId;
    if (from == null) {
      token.claim(_clientId, now);
    } else {
      token.handOver(from, _clientId, now);
      _server._takenFrom[session.id] = from;
    }
    final grid = flow.wantedGrid;
    if (grid != null) _server._sizedBy(session, _clientId);
    if (grid != null &&
        (grid.$1 != session.columns || grid.$2 != session.rows)) {
      session.resize(_clientId, grid.$1, grid.$2, now);
    }
    _server._presenceChanged(session);
  }

  /// The holder's grid wins: a claiming viewer's size is kept for when it
  /// takes the input, and it renders the holder's meanwhile. A ref that only
  /// looks (a phone) is not resized for at all until it claims.
  void _onResize(ResizeMessage message) {
    if (_relays(message.sessionRef)) return _boxes.resize(message);
    final flow = _flows[message.sessionRef];
    if (flow == null) return _sendUnknownRef(message.sessionRef);
    final session = flow.session;
    final holds = session.token.isHeldBy(_clientId);
    if (!holds && !flow.claims) return;
    flow.wantedGrid = (message.columns, message.rows);
    if (!holds) return;
    _server._sizedBy(session, _clientId);
    session.resize(_clientId, message.columns, message.rows, _server.now());
    _server._presenceChanged(session);
  }

  void _onClaim(ClaimMessage message) {
    if (_relays(message.sessionRef)) return _boxes.claim(message);
    final flow = _flows[message.sessionRef];
    if (flow == null) return _sendUnknownRef(message.sessionRef);
    final token = flow.session.token;
    final now = _server.now();
    flow.claims = true;
    if (!token.isHeldBy(_clientId)) {
      if (!message.takeOver && token.isHeld) {
        _send(
          ErrorMessage(
            message.requestId,
            ProtocolErrorCode.writeRefused,
            ClaimRefusal.heldBy(token.holder!, now).message,
          ),
        );
        return;
      }
      _takeToken(flow, now);
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
    if (_relays(message.sessionRef)) return _boxes.release(message);
    final flow = _flows[message.sessionRef];
    if (flow == null) return _sendUnknownRef(message.sessionRef);
    final token = flow.session.token;
    _server._giveBackSize(flow.session, _clientId);
    token.release(_clientId);
    _send(
      ClaimedMessage(
        requestId: message.requestId,
        sessionRef: message.sessionRef,
        holdsWriteToken: false,
        writeHolder: token.holder?.clientId,
      ),
    );
    _server._presenceChanged(flow.session);
  }

  /// Stops one attachment's stream and frees its ref (slice 5d); the session
  /// goes on.
  Future<void> _onDetach(int ref) async {
    if (_relays(ref)) return _boxes.detach(ref);
    final flow = _flows.remove(ref);
    if (flow == null) return;
    await flow.subscription?.cancel();
    await flow.exitWatch?.cancel();
    _server._detached(flow.session, this, ref);
  }

  Future<void> _onClose(CloseMessage message) async {
    if (_onBox(message.sessionId)) return _boxes.close(message);
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
