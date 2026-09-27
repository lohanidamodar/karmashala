import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';

/// The box host's refusal, or no answer, in words.
class BoxLinkException implements Exception {
  const BoxLinkException(this.message, {this.code, this.timedOut = false});

  final String message;
  final ProtocolErrorCode? code;
  final bool timedOut;

  @override
  String toString() => message;
}

/// One attachment on a [BoxLink]: the box's answer, then the frames for its
/// ref — output, a screen, the exit — in order. The stream ends when the
/// attachment is detached or the link drops.
class BoxRoute {
  BoxRoute._(this._link, this.attached);

  final BoxLink _link;

  /// What the box answered: its ref for this attachment, the grid it holds
  /// the session at, where its output resumes.
  final AttachedMessage attached;

  final _frames = StreamController<HostMessage>();
  var _ended = false;

  Stream<HostMessage> get frames => _frames.stream;

  /// Whether the box has told this attachment's session ended.
  bool get exited => _exited;
  var _exited = false;

  void input(Uint8List bytes) {
    if (_ended || bytes.isEmpty) return;
    _link._send(InputMessage(attached.sessionRef, bytes));
  }

  void resize(int columns, int rows) {
    if (_ended) return;
    _link._send(ResizeMessage(attached.sessionRef, columns, rows));
  }

  /// Stops this attachment's stream at the box; the session goes on.
  void detach() {
    if (_ended) return;
    _link._send(DetachMessage(attached.sessionRef));
    _link._routes.remove(attached.sessionRef);
    _end();
  }

  void _add(HostMessage message) {
    if (_ended) return;
    if (message is ExitedMessage) _exited = true;
    _frames.add(message);
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    unawaited(_frames.close());
  }
}

/// **The client side of a link to the host on an SSH box** (slice 5d) — the
/// server keeps one per box: the host protocol over an exec channel running
/// `karmashala_host attach` there.
/// Every attachment the server makes on the box — its own copy of each
/// session's screen, and each client pane it relays — is a ref on this one
/// link. It also watches the box's lifecycle, so an exit is the box's fact.
class BoxLink {
  BoxLink._(this._channel, this.hostId, this.clientId, this._bound);

  final RemoteChannel _channel;
  final String hostId;

  /// Who the box sees driving every session on this link: the server. A
  /// client's write right is kept at the server (`WriteToken` per session).
  final String clientId;
  final Duration _bound;

  final _parser = FrameParser();
  final _pending = <int, Completer<HostMessage>>{};
  final _routes = <int, BoxRoute>{};
  final _events = StreamController<HostMessage>.broadcast(sync: true);
  final _closed = Completer<String>();
  StreamSubscription<Uint8List>? _subscription;
  int _requestId = 0;
  WelcomeMessage? _welcome;
  var _down = false;

  /// What the box's host said when greeted: its version, pid and OS.
  WelcomeMessage get welcome => _welcome!;

  /// The box's lifecycle as it happens — `LifecycleMessage`, `HookMessage`,
  /// `AgentStatusMessage` — after the snapshot [watch] answers with.
  Stream<HostMessage> get events => _events.stream;

  /// Completes, with why, when the link is gone. Every route has ended by
  /// then; the sessions go on at the box.
  Future<String> get closed => _closed.future;

  bool get isDown => _down;

  /// Greets the box's host over [channel]. Throws [BoxLinkException] when it
  /// will not answer, or speaks another protocol.
  static Future<BoxLink> connect(
    RemoteChannel channel, {
    required String hostId,
    String clientId = 'karmashala-server',
    Duration bound = const Duration(seconds: 20),
  }) async {
    final link = BoxLink._(channel, hostId, clientId, bound);
    link._subscription = channel.stdout.listen(
      link._onBytes,
      onError: (Object error) => link._fail('$error'),
      onDone: () => link._fail('the box host\'s channel closed'),
    );
    final welcome = await link._request<WelcomeMessage>(
      (id) => HelloMessage(requestId: id, clientId: clientId),
    );
    if (welcome.protocolVersion != kProtocolVersion) {
      await link.close();
      throw BoxLinkException(
        'the host on the box speaks protocol ${welcome.protocolVersion}; '
        'this server speaks $kProtocolVersion',
        code: ProtocolErrorCode.protocolMismatch,
      );
    }
    link._welcome = welcome;
    return link;
  }

  /// Watches the box's lifecycle: answers the snapshot, then tells each event
  /// on [events].
  Future<WatchingMessage> watch() =>
      _request<WatchingMessage>(WatchMessage.new);

  /// Starts [sessionId] on the box and attaches to it, holding the write
  /// right. Refused with [ProtocolErrorCode.sessionExists] when the box
  /// already has it.
  Future<BoxRoute> open({
    required String sessionId,
    required List<String> argv,
    String? workingDirectory,
    Map<String, String> environment = const {},
    Set<String> removedEnvironment = const {},
    required int columns,
    required int rows,
  }) => _attach(
    (id) => OpenMessage(
      requestId: id,
      sessionId: sessionId,
      argv: argv,
      workingDirectory: workingDirectory,
      environment: environment,
      removedEnvironment: removedEnvironment,
      columns: columns,
      rows: rows,
    ),
  );

  /// Attaches to [sessionId] on the box: its output from [sinceOffset], or
  /// — with [screenGrid] — its screen at that grid, then live output.
  Future<BoxRoute> attach({
    required String sessionId,
    int sinceOffset = 0,
    (int, int)? screenGrid,
  }) => _attach(
    (id) => AttachMessage(
      requestId: id,
      sessionId: sessionId,
      sinceOffset: sinceOffset,
      claimWrite: true,
      screenGrid: screenGrid,
    ),
  );

  /// Every session the box holds, ended ones included.
  Future<List<SessionSummary>> list() async =>
      (await _request<SessionsMessage>(ListMessage.new)).summaries;

  /// Ends [sessionId] on the box for good: its exit code, when it had one.
  Future<int?> closeSession(String sessionId, {int signal = 15}) async =>
      (await _request<ClosedMessage>(
        (id) => CloseMessage(id, sessionId, signal: signal),
      )).exitCode;

  /// Hangs up. The box frees the write rights and keeps every session.
  Future<void> close() async {
    if (_down) return;
    _fail('closed by the server');
    await _subscription?.cancel();
    await _channel.close();
  }

  Future<BoxRoute> _attach(HostMessage Function(int requestId) build) async {
    final attached = await _request<AttachedMessage>(build);
    // Registered when the answer was read (below), so no frame that followed
    // it in the same chunk is lost.
    final route = _routes[attached.sessionRef];
    if (route == null) {
      throw const BoxLinkException('the box host\'s link closed first');
    }
    return route;
  }

  void _onBytes(Uint8List chunk) {
    final List<Frame> frames;
    try {
      frames = _parser.add(chunk);
    } on FrameFormatException catch (e) {
      _fail('the box host sent something unreadable: ${e.message}');
      return;
    }
    for (final frame in frames) {
      final HostMessage message;
      try {
        message = decodeMessage(frame);
      } on Object catch (e) {
        _fail('the box host sent something unreadable: $e');
        return;
      }
      switch (message) {
        case OutputMessage(:final sessionRef):
        case ScreenMessage(:final sessionRef):
          _routes[sessionRef]?._add(message);
        case ExitedMessage(:final sessionRef):
          _routes[sessionRef]?._add(message);
        case AttachedMessage(:final requestId, :final sessionRef):
          _routes[sessionRef] = BoxRoute._(this, message);
          _pending.remove(requestId)?.complete(message);
        case ErrorMessage(:final requestId):
          final waiting = _pending.remove(requestId);
          if (waiting != null) {
            waiting.completeError(
              BoxLinkException(message.message, code: message.code),
            );
          } else if (requestId == 0 &&
              message.code == ProtocolErrorCode.badRequest) {
            _fail('the box host refused a frame: ${message.message}');
            return;
          }
        case WelcomeMessage(:final requestId):
        case SessionsMessage(:final requestId):
        case ClosedMessage(:final requestId):
        case ClaimedMessage(:final requestId):
        case WatchingMessage(:final requestId):
          _pending.remove(requestId)?.complete(message);
        case LifecycleMessage():
        case HookMessage():
        case AgentStatusMessage():
          if (!_events.isClosed) _events.add(message);
        default:
          break;
      }
    }
  }

  void _fail(String why) {
    if (_down) return;
    _down = true;
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) {
        waiting.completeError(BoxLinkException('the link to the box: $why'));
      }
    }
    _pending.clear();
    for (final route in _routes.values.toList()) {
      route._end();
    }
    _routes.clear();
    unawaited(_events.close());
    if (!_closed.isCompleted) _closed.complete(why);
  }

  void _send(HostMessage message) {
    if (_down) return;
    try {
      _channel.add(message.toFrame().encode());
    } on Object catch (error) {
      _fail('$error');
    }
  }

  Future<T> _request<T extends HostMessage>(
    HostMessage Function(int requestId) build,
  ) {
    if (_down) {
      return Future.error(
        const BoxLinkException('the link to the box is closed'),
      );
    }
    final id = ++_requestId;
    final completer = Completer<HostMessage>();
    _pending[id] = completer;
    _send(build(id));
    return completer.future
        .timeout(
          _bound,
          onTimeout: () {
            _pending.remove(id);
            throw BoxLinkException(
              'the box host did not answer in ${_bound.inSeconds}s',
              timedOut: true,
            );
          },
        )
        .then((message) => message as T);
  }
}
