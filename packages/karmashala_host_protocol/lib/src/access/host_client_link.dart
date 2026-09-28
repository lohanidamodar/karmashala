import 'dart:async';
import 'dart:typed_data';

import '../protocol/frame.dart';
import '../protocol/messages.dart';
import 'remote_channel.dart';

/// A link that would not open, or that closed under a request.
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

/// **One client's one connection to a server** (slice 5e): a single `hello`,
/// then every pane's attachment (by ref), the data API, the lifecycle feed
/// and prompt answers multiplexed over it. Replies are matched by request
/// id, per-attachment frames by ref, and everything else is on [messages].
class HostClientLink {
  HostClientLink._(this._channel, this.clientId);

  /// Says `hello` over [channel] and waits for the welcome. Throws
  /// [HostLinkException] when the host will not answer or speaks another
  /// protocol; the channel is closed then.
  static Future<HostClientLink> open(
    RemoteChannel channel, {
    required String clientId,
    int features = HelloMessage.acksOutput,
    Duration bound = const Duration(seconds: 20),
  }) async {
    final link = HostClientLink._(channel, clientId).._listen();
    try {
      final welcome = await link.request<WelcomeMessage>(
        (id) => HelloMessage(
          requestId: id,
          clientId: clientId,
          features: features,
        ),
        bound,
      );
      if (welcome.protocolVersion != kProtocolVersion) {
        throw HostLinkException(
          'The host speaks protocol ${welcome.protocolVersion}; this app '
          'speaks $kProtocolVersion.',
          code: ProtocolErrorCode.protocolMismatch,
        );
      }
      link._welcome = welcome;
      link.acksOutput = features & HelloMessage.acksOutput != 0;
    } on Object {
      await link.close();
      rethrow;
    }
    return link;
  }

  final RemoteChannel _channel;
  final String clientId;

  /// Whether this client promised [OutputAckMessage]s in its hello.
  var acksOutput = false;

  final _parser = FrameParser();
  final _pending = <int, Completer<HostMessage>>{};
  final _refs = <int, StreamController<HostMessage>>{};
  final _messages = StreamController<HostMessage>.broadcast(sync: true);
  final _done = Completer<void>();
  StreamSubscription<Uint8List>? _subscription;
  WelcomeMessage? _welcome;
  var _lastId = 0;
  String? _closeReason;

  WelcomeMessage get welcome => _welcome!;

  bool get isClosed => _done.isCompleted;

  /// Completes once the link is over, from either side.
  Future<void> get done => _done.future;

  /// Why the link ended, once it has.
  String? get closeReason => _closeReason;

  /// Every frame that answers no request and belongs to no attachment: data
  /// answers and changes, the lifecycle feed, unsolicited refusals.
  Stream<HostMessage> get messages => _messages.stream;

  int nextRequestId() => ++_lastId;

  void send(HostMessage message) {
    if (isClosed) return;
    try {
      _channel.add(message.toFrame().encode());
    } on Object {
      // The channel went away; its end reports it once.
    }
  }

  /// Sends what [build] makes under a fresh id and waits [bound] (none when
  /// null) for the reply with that id — or the refusal.
  Future<T> request<T extends HostMessage>(
    HostMessage Function(int requestId) build,
    Duration? bound,
  ) {
    if (isClosed) {
      return Future.error(
        HostLinkException(_closeReason ?? 'The link closed first.'),
      );
    }
    final id = nextRequestId();
    final completer = Completer<HostMessage>();
    _pending[id] = completer;
    send(build(id));
    var answer = completer.future;
    if (bound != null) {
      answer = answer.timeout(
        bound,
        onTimeout: () {
          _pending.remove(id);
          throw HostLinkException(
            'The host did not answer in ${_describe(bound)}.',
            timedOut: true,
          );
        },
      );
    }
    return answer.then((message) => message as T);
  }

  /// The frames the host addresses to [ref] — output, the screen, presence,
  /// the exit, refusals — buffered from the moment its attach was answered
  /// until somebody listens. Empty for a ref this link does not hold.
  Stream<HostMessage> framesFor(int ref) =>
      _refs[ref]?.stream ?? const Stream<HostMessage>.empty();

  /// Stops [ref]'s stream at the host and here; the session goes on.
  void detach(int ref) {
    final controller = _refs.remove(ref);
    if (controller == null) return;
    send(DetachMessage(ref));
    unawaited(controller.close());
  }

  Future<void> close() async {
    _end('The link closed.');
    await _subscription?.cancel();
    _subscription = null;
    await _channel.close();
  }

  void _listen() {
    _subscription = _channel.stdout.listen(
      _onBytes,
      onError: (Object error) => _end('$error'),
      onDone: () => _end('The host channel closed.'),
    );
  }

  void _onBytes(Uint8List chunk) {
    final List<Frame> frames;
    try {
      frames = _parser.add(chunk);
    } on FrameFormatException catch (e) {
      _end('The host sent something unreadable: ${e.message}');
      unawaited(_channel.close());
      return;
    }
    for (final frame in frames) {
      final HostMessage message;
      try {
        message = decodeMessage(frame);
      } on Object catch (e) {
        // A newer host's news this build cannot read (a lifecycle kind it
        // does not know) is skipped; an answer that cannot be read ends the
        // link, rather than leave its request to time out.
        if (_skippable.contains(frame.type)) continue;
        _end('The host sent something unreadable: $e');
        unawaited(_channel.close());
        return;
      }
      _dispatch(message);
      if (isClosed) return;
    }
  }

  void _dispatch(HostMessage message) {
    if (message case AttachedMessage(:final requestId, :final sessionRef)) {
      // Opened before anyone hears of the attachment: its output follows in
      // the same chunk, ahead of the microtask that delivers the answer.
      if (_pending.containsKey(requestId)) {
        _refs[sessionRef] = StreamController<HostMessage>();
      } else {
        send(DetachMessage(sessionRef));
        return;
      }
    }
    final id = _replyIdOf(message);
    if (id != null) {
      final waiting = _pending.remove(id);
      if (waiting != null) {
        if (message case ErrorMessage(:final code, message: final text)) {
          waiting.completeError(HostLinkException(text, code: code));
        } else {
          waiting.complete(message);
        }
        return;
      }
    }
    final ref = _refOf(message);
    if (ref != 0) {
      final controller = _refs[ref];
      if (controller != null && !controller.isClosed) controller.add(message);
      return;
    }
    if (message case ErrorMessage(
      requestId: 0,
      code: ProtocolErrorCode.badRequest,
    ) when _pending.isNotEmpty) {
      // A frame the host could not read answers id 0 and hangs up: that is
      // the answer to what is waiting.
      _end(message.message, code: message.code);
      return;
    }
    if (!_messages.isClosed) _messages.add(message);
  }

  static const _skippable = {
    MessageType.lifecycle,
    MessageType.hook,
    MessageType.agentStatus,
    MessageType.companionEvent,
    MessageType.dataChanges,
    MessageType.dataStreamItems,
    MessageType.presence,
  };

  static int? _replyIdOf(HostMessage message) => switch (message) {
    WelcomeMessage(:final requestId) ||
    AttachedMessage(:final requestId) ||
    SessionsMessage(:final requestId) ||
    ClosedMessage(:final requestId) ||
    ClaimedMessage(:final requestId) ||
    PairedMessage(:final requestId) ||
    WatchingMessage(:final requestId) ||
    PromptAnsweredMessage(:final requestId) ||
    ServerResultMessage(:final requestId) => requestId,
    ErrorMessage(:final requestId) when requestId != 0 => requestId,
    _ => null,
  };

  static int _refOf(HostMessage message) => switch (message) {
    OutputMessage(:final sessionRef) ||
    ScreenMessage(:final sessionRef) ||
    ExitedMessage(:final sessionRef) ||
    PresenceMessage(:final sessionRef) ||
    ErrorMessage(:final sessionRef) => sessionRef,
    _ => 0,
  };

  void _end(String reason, {ProtocolErrorCode? code}) {
    if (_done.isCompleted) return;
    _closeReason = reason;
    final error = HostLinkException(reason, code: code);
    for (final waiting in _pending.values) {
      if (!waiting.isCompleted) waiting.completeError(error);
    }
    _pending.clear();
    for (final controller in _refs.values) {
      unawaited(controller.close());
    }
    _refs.clear();
    unawaited(_messages.close());
    _done.complete();
  }
}

String _describe(Duration bound) =>
    bound.inSeconds >= 1 ? '${bound.inSeconds}s' : '${bound.inMilliseconds}ms';
