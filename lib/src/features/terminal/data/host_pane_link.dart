import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/protocol.dart';

import 'package:karmashala_ssh/host.dart';

/// What the host said when a pane attached.
class HostAttachment {
  const HostAttachment({
    required this.sessionRef,
    required this.sessionId,
    required this.replayFromOffset,
    required this.droppedBytes,
    required this.totalBytes,
    required this.holdsWriteToken,
    required this.writeHolder,
    required this.observedAt,
  });

  final int sessionRef;
  final String sessionId;
  final int replayFromOffset;

  /// How much the ring had already overwritten. Non-zero means the pane is
  /// missing scrollback, and it says so rather than showing a seamless lie.
  final int droppedBytes;
  final int totalBytes;
  final bool holdsWriteToken;
  final String? writeHolder;
  final DateTime observedAt;
}

/// The app's end of the host protocol, over one channel. It relays bytes and
/// normalises nothing — the entire reason the host exists rather than tmux.
class HostPaneLink {
  HostPaneLink._(this._channel, this.clientId);

  final RemoteChannel _channel;
  final String clientId;

  final _parser = FrameParser();
  final _output = StreamController<Uint8List>();
  final _notices = StreamController<String>.broadcast();
  final _pending = <int, Completer<HostMessage>>{};
  final _exit = Completer<HostSessionEnd>();

  StreamSubscription<Uint8List>? _subscription;
  WelcomeMessage? _welcome;
  int _sessionRef = 0;
  int _requestId = 0;
  var _closed = false;

  /// The absolute offset of the last byte handed to the terminal. This is what
  /// a reattach asks from, so nothing is replayed twice or lost.
  int lastOffset = 0;

  WelcomeMessage? get welcome => _welcome;

  /// Raw bytes from the child. Closed when the channel goes away.
  Stream<Uint8List> get output => _output.stream;

  /// Things worth telling the user: a refused write, a gap in the backlog.
  Stream<String> get notices => _notices.stream;

  /// Completes when the session ends. A missing code stays missing.
  Future<HostSessionEnd> get ended => _exit.future;

  /// Sends `hello` and waits for the host to answer. Throws
  /// [HostLinkException] when it will not, or speaks another protocol.
  static Future<HostPaneLink> open(
    RemoteChannel channel, {
    required String clientId,
    Duration bound = const Duration(seconds: 20),
  }) async {
    final link = HostPaneLink._(channel, clientId);
    link._listen();
    final welcome = await link._request<WelcomeMessage>(
      (id) => HelloMessage(requestId: id, clientId: clientId),
      bound,
    );
    if (welcome.protocolVersion != kProtocolVersion) {
      await link.close();
      throw HostLinkException(
        'The host speaks protocol ${welcome.protocolVersion}; this app speaks '
        '$kProtocolVersion.',
      );
    }
    link._welcome = welcome;
    return link;
  }

  Future<HostAttachment> openSession({
    required String sessionId,
    required List<String> argv,
    String? workingDirectory,
    Map<String, String> environment = const {},
    required int columns,
    required int rows,
  }) => _attachment(
    (id) => OpenMessage(
      requestId: id,
      sessionId: sessionId,
      argv: argv,
      workingDirectory: workingDirectory,
      environment: environment,
      columns: columns,
      rows: rows,
    ),
  );

  /// Reattaches from [sinceOffset] — the last offset this pane rendered.
  Future<HostAttachment> attachSession({
    required String sessionId,
    required int sinceOffset,
    bool claimWrite = true,
  }) => _attachment(
    (id) => AttachMessage(
      requestId: id,
      sessionId: sessionId,
      sinceOffset: sinceOffset,
      claimWrite: claimWrite,
    ),
  );

  Future<HostAttachment> _attachment(HostMessage Function(int) build) async {
    final attached = await _request<AttachedMessage>(build, const Duration(seconds: 20));
    _sessionRef = attached.sessionRef;
    lastOffset = attached.replayFromOffset;
    if (attached.droppedBytes > 0) {
      _notices.add(
        'The host had already discarded ${attached.droppedBytes} bytes of this '
        "session's output; the pane is resuming from where it still has it.",
      );
    }
    if (!attached.holdsWriteToken) {
      _notices.add(
        attached.writeHolder == null
            ? 'This pane is attached read-only.'
            : 'This pane is attached read-only; ${attached.writeHolder} is driving it.',
      );
    }
    return HostAttachment(
      sessionRef: attached.sessionRef,
      sessionId: attached.sessionId,
      replayFromOffset: attached.replayFromOffset,
      droppedBytes: attached.droppedBytes,
      totalBytes: attached.totalBytes,
      holdsWriteToken: attached.holdsWriteToken,
      writeHolder: attached.writeHolder,
      observedAt: attached.observedAt,
    );
  }

  /// Ends a session on the host for good. Never called by a pane closing —
  /// that is a *disconnect*, and surviving one is the whole point.
  Future<void> closeSession(String sessionId) async {
    if (_closed) return;
    try {
      await _request<ClosedMessage>(
        (id) => CloseMessage(id, sessionId),
        const Duration(seconds: 10),
      );
    } on HostLinkException {
      // Already gone, or the link went with it. Either way there is nothing
      // left to clear away and nothing a pane could do about it.
    }
  }

  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    _send(InputMessage(_sessionRef, bytes));
  }

  void resize(int columns, int rows) {
    if (_closed) return;
    _send(ResizeMessage(_sessionRef, columns, rows));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    // Closing our end is the disconnect. The host frees the write token and
    // keeps the session running — that is the whole point.
    await _channel.close();
    // Not awaited: closing a single-subscription controller nobody has listened
    // to never completes, and a pane that failed before its first frame is
    // exactly that case.
    if (!_output.isClosed) unawaited(_output.close());
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const HostLinkException('The link closed first.'));
      }
    }
    _pending.clear();
    await _notices.close();
  }

  void _listen() {
    _subscription = _channel.stdout.listen(
      _onBytes,
      onError: (Object error) => _fail(HostLinkException('$error')),
      onDone: () => _fail(const HostLinkException('The host channel closed.')),
    );
  }

  void _onBytes(Uint8List chunk) {
    final List<Frame> frames;
    try {
      frames = _parser.add(chunk);
    } on FrameFormatException catch (e) {
      _fail(HostLinkException('The host sent something unreadable: ${e.message}'));
      return;
    }
    for (final frame in frames) {
      final HostMessage message;
      try {
        message = decodeMessage(frame);
      } on Object catch (e) {
        _fail(HostLinkException('The host sent something unreadable: $e'));
        return;
      }
      switch (message) {
        case OutputMessage():
          // Bytes straight through, and the offset recorded so a reconnect
          // asks for exactly what comes next.
          if (!_output.isClosed) _output.add(message.bytes);
          lastOffset = message.nextOffset;
        case ExitedMessage():
          if (!_exit.isCompleted) {
            _exit.complete(HostSessionEnd(message.exitCode, message.reason, message.observedAt));
          }
        case ErrorMessage():
          final waiting = _pending.remove(message.requestId);
          if (waiting != null && !waiting.isCompleted) {
            waiting.completeError(HostLinkException(message.message, code: message.code));
          } else if (!_notices.isClosed) {
            // Unsolicited: a refused write, most often.
            _notices.add(message.message);
          }
        case WelcomeMessage(:final requestId):
        case AttachedMessage(:final requestId):
        case SessionsMessage(:final requestId):
        case ClosedMessage(:final requestId):
        case ClaimedMessage(:final requestId):
          _pending.remove(requestId)?.complete(message);
        default:
          break;
      }
    }
  }

  void _fail(HostLinkException error) {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    if (!_output.isClosed) _output.close();
    if (!_notices.isClosed) _notices.close();
  }

  void _send(HostMessage message) {
    try {
      _channel.add(message.toFrame().encode());
    } on Object {
      // The channel went away; onDone or onError will report it once.
    }
  }

  Future<T> _request<T extends HostMessage>(
    HostMessage Function(int requestId) build,
    Duration bound,
  ) {
    final id = ++_requestId;
    final completer = Completer<HostMessage>();
    _pending[id] = completer;
    _send(build(id));
    // A bound on an answer over a network. Nothing asks twice.
    return completer.future
        .timeout(
          bound,
          onTimeout: () {
            _pending.remove(id);
            throw HostLinkException(
              'The host did not answer in ${_describe(bound)}.',
              // A bound that expired is a reading of how busy the machine was,
              // and callers that would otherwise act on it as "nobody is there"
              // need to be able to tell the two apart.
              timedOut: true,
            );
          },
        )
        .then((message) => message as T);
  }
}

/// How a hosted session ended. A null [exitCode] is genuinely unknown and is
/// never rendered as a zero.
class HostSessionEnd {
  const HostSessionEnd(this.exitCode, this.reason, this.observedAt);
  final int? exitCode;
  final String reason;
  final DateTime observedAt;
}

class HostLinkException implements Exception {
  const HostLinkException(this.message, {this.timedOut = false, this.code});
  final String message;

  /// The host's refusal code, when the host said something at all.
  final ProtocolErrorCode? code;

  /// Whether the bound expired rather than the host saying something.
  final bool timedOut;

  @override
  String toString() => message;
}

/// Seconds read better than `0:00:05.000000`, and a sub-second bound needs ms.
String _describe(Duration bound) =>
    bound.inSeconds >= 1 ? '${bound.inSeconds}s' : '${bound.inMilliseconds}ms';
