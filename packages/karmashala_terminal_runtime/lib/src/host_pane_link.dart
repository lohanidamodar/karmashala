import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart';

export 'package:karmashala_host_protocol/host_access.dart'
    show HostClientLink, HostLinkException;

/// What the host said when a pane attached.
class HostAttachment {
  const HostAttachment({
    required this.sessionRef,
    required this.sessionId,
    required this.columns,
    required this.rows,
    required this.replayFromOffset,
    required this.droppedBytes,
    required this.totalBytes,
    required this.holdsWriteToken,
    required this.writeHolder,
    required this.observedAt,
    this.screenFollows = false,
  });

  /// The host sent the session's screen instead of its output: the first
  /// bytes on [HostPaneLink.output] rebuild it, and live output follows.
  final bool screenFollows;

  final int sessionRef;
  final String sessionId;

  /// The grid the host holds the session at — its previous pane's, if found.
  final int columns;
  final int rows;
  final int replayFromOffset;

  /// How much the ring had already overwritten. Non-zero means the pane is
  /// missing scrollback, and it says so rather than showing a seamless lie.
  final int droppedBytes;
  final int totalBytes;
  final bool holdsWriteToken;
  final String? writeHolder;
  final DateTime observedAt;
}

/// Who drives a session this pane shows, and who else watches it (slice
/// 5e), as the host last told it.
class HostPresence {
  const HostPresence({
    required this.holder,
    required this.viewers,
    required this.sizedFor,
    required this.columns,
    required this.rows,
    required this.me,
  });

  final String? holder;
  final List<String> viewers;
  final String? sizedFor;
  final int columns;
  final int rows;

  /// This client's own id, so a pane can tell "me" from someone else.
  final String me;

  bool get mine => holder == me;

  /// Someone else is typing here.
  bool get heldElsewhere => holder != null && holder != me;

  /// The session is at another client's grid.
  bool get sizedElsewhere => sizedFor != null && sizedFor != me;

  /// No other client has the session open, typing or only looking.
  bool get alone => !heldElsewhere && viewers.every((viewer) => viewer == me);
}

/// One pane's attachment on a client's link to its server. Many panes share
/// one [HostClientLink] (slice 5e): each has its own ref, its own output and
/// exit, and closing it lets go of that ref only. [open] still makes a link
/// of its own, for a one-off question (a probe, a session list).
class HostPaneLink {
  HostPaneLink._(this._link, this._owns, this._attachBound);

  final HostClientLink _link;
  final bool _owns;

  /// How long an open or attach is given before its reply counts as lost.
  final Duration _attachBound;

  final _output = StreamController<Uint8List>();
  final _notices = StreamController<String>.broadcast();
  final _presence = StreamController<HostPresence>.broadcast();
  final _refused = StreamController<void>.broadcast();
  final _exit = Completer<HostSessionEnd>();

  StreamSubscription<HostMessage>? _frames;
  int _sessionRef = 0;
  var _closed = false;
  HostPresence? _lastPresence;

  /// The absolute offset of the last byte handed to the terminal. This is what
  /// a reattach asks from, so nothing is replayed twice or lost.
  int lastOffset = 0;
  int _ackedOffset = 0;
  Timer? _ackTimer;

  /// Acknowledged after this much, or shortly after the last byte.
  static const int _ackEvery = 64 * 1024;

  WelcomeMessage? get welcome => _link.isClosed ? null : _link.welcome;

  String get clientId => _link.clientId;

  /// Raw bytes from the child. Closed when the attachment or the link ends.
  Stream<Uint8List> get output => _output.stream;

  /// Things worth telling the user: a refused write, a gap in the backlog.
  Stream<String> get notices => _notices.stream;

  /// Who drives the session and who watches, each time that changes.
  Stream<HostPresence> get presence => _presence.stream;
  HostPresence? get lastPresence => _lastPresence;

  /// A keystroke refused because someone else is typing: the presence cover
  /// says so, rather than a line per key in the screen.
  Stream<void> get refusedWrites => _refused.stream;

  /// Completes when the session ends. A missing code stays missing.
  Future<HostSessionEnd> get ended => _exit.future;

  /// Sends `hello` over a channel of its own and waits for the host to
  /// answer. Throws [HostLinkException] when it will not, or speaks another
  /// protocol.
  static Future<HostPaneLink> open(
    RemoteChannel channel, {
    required String clientId,
    Duration bound = const Duration(seconds: 20),
    Duration attachBound = const Duration(seconds: 20),
  }) async {
    final link = await HostClientLink.open(
      channel,
      clientId: clientId,
      bound: bound,
    );
    return HostPaneLink._(link, true, attachBound).._watchLink();
  }

  /// A pane's attachment on the client's shared [link].
  static HostPaneLink on(
    HostClientLink link, {
    Duration attachBound = const Duration(seconds: 20),
  }) => HostPaneLink._(link, false, attachBound).._watchLink();

  void _watchLink() {
    unawaited(
      _link.done.then((_) => _fail(_link.closeReason ?? 'The link closed.')),
    );
  }

  Future<HostAttachment> openSession({
    required String sessionId,
    required List<String> argv,
    String? workingDirectory,
    Map<String, String> environment = const {},
    Set<String> removedEnvironment = const {},
    required int columns,
    required int rows,
  }) => _attachment(
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

  /// [open], or — when its answer was lost or the host says the session already
  /// exists — the session that is there, adopted. The host's record of the id
  /// is the receipt: asking for it is how a lost reply is checked, so a second
  /// process is never started for the same pane. [adopted] is told when it was.
  Future<HostAttachment> openOrAdopt(
    String sessionId,
    Future<HostAttachment> Function() open, {
    void Function()? adopted,
  }) async {
    try {
      return await open();
    } on HostLinkException catch (e) {
      final lostReply = e.timedOut;
      if (!lostReply && e.code != ProtocolErrorCode.sessionExists) rethrow;
      try {
        final found = await attachSession(sessionId: sessionId, sinceOffset: 0);
        adopted?.call();
        return found;
      } on HostLinkException catch (check) {
        // Checked, and not there: the open never happened, so say what it met.
        if (check.code == ProtocolErrorCode.unknownSession) throw e;
        rethrow;
      }
    }
  }

  /// Reattaches from [sinceOffset] — the last offset this pane rendered.
  /// With [screenGrid], asks for the session's screen at that grid rather
  /// than its output.
  Future<HostAttachment> attachSession({
    required String sessionId,
    required int sinceOffset,
    bool claimWrite = true,
    (int, int)? screenGrid,
  }) => _attachment(
    (id) => AttachMessage(
      requestId: id,
      sessionId: sessionId,
      sinceOffset: sinceOffset,
      claimWrite: claimWrite,
      screenGrid: screenGrid,
    ),
  );

  Future<HostAttachment> _attachment(HostMessage Function(int) build) async {
    final attached = await _link.request<AttachedMessage>(build, _attachBound);
    _sessionRef = attached.sessionRef;
    lastOffset = attached.replayFromOffset;
    _ackedOffset = lastOffset;
    _frames = _link.framesFor(_sessionRef).listen(_onFrame, onDone: _refEnded);
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
            : 'This pane is attached read-only; ${attached.writeHolder} is '
                  'driving it.',
      );
    }
    return HostAttachment(
      sessionRef: attached.sessionRef,
      sessionId: attached.sessionId,
      columns: attached.columns,
      rows: attached.rows,
      replayFromOffset: attached.replayFromOffset,
      droppedBytes: attached.droppedBytes,
      totalBytes: attached.totalBytes,
      holdsWriteToken: attached.holdsWriteToken,
      writeHolder: attached.writeHolder,
      observedAt: attached.observedAt,
      screenFollows: attached.screenFollows,
    );
  }

  /// Every session this host holds, ended ones included.
  Future<List<SessionSummary>> listSessions() async {
    final answer = await _link.request<SessionsMessage>(
      ListMessage.new,
      const Duration(seconds: 20),
    );
    return answer.summaries;
  }

  /// Ends a session on the host for good. Never called by a pane closing —
  /// that is a *disconnect*, and surviving one is the whole point.
  Future<void> closeSession(String sessionId) async {
    if (_link.isClosed) return;
    try {
      await _link.request<ClosedMessage>(
        (id) => CloseMessage(id, sessionId),
        const Duration(seconds: 10),
      );
    } on HostLinkException {
      // Already gone, or the link went with it.
    }
  }

  /// Takes the write token from whoever holds it — a person's "Take over".
  Future<void> takeOver() async {
    if (_closed || _sessionRef == 0) return;
    try {
      await _link.request<ClaimedMessage>(
        (id) => ClaimMessage(id, _sessionRef, takeOver: true),
        const Duration(seconds: 10),
      );
    } on HostLinkException catch (e) {
      if (!_notices.isClosed) _notices.add(e.message);
    }
  }

  /// Lets go of the write token, so the host can give the session back to
  /// the client it was taken from.
  Future<void> release() async {
    if (_closed || _sessionRef == 0) return;
    try {
      await _link.request<ClaimedMessage>(
        (id) => ReleaseMessage(id, _sessionRef),
        const Duration(seconds: 10),
      );
    } on HostLinkException {
      // A link gone with it has let go already.
    }
  }

  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty || _sessionRef == 0) return;
    _link.send(InputMessage(_sessionRef, bytes));
  }

  /// Nothing before the host names the session: ref 0 is refused. [matchGrid]
  /// says the size once it has.
  void resize(int columns, int rows) {
    if (_closed || _sessionRef == 0) return;
    _link.send(ResizeMessage(_sessionRef, columns, rows));
  }

  /// Tells the host the pane's grid when [attachment] found the session at
  /// another: a pane is laid out before its link exists to carry the resize.
  /// A pane that does not drive says it too: the host keeps it for a claim.
  void matchGrid(HostAttachment attachment, int columns, int rows) {
    if (attachment.columns == columns && attachment.rows == rows) return;
    resize(columns, rows);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ackTimer?.cancel();
    await _frames?.cancel();
    if (_owns) {
      // Closing our end is the disconnect: the host frees the write token and
      // keeps the session running.
      await _link.close();
    } else if (_sessionRef != 0) {
      _link.detach(_sessionRef);
    }
    if (!_output.isClosed) unawaited(_output.close());
    await _notices.close();
    await _presence.close();
    await _refused.close();
  }

  void _onFrame(HostMessage message) {
    switch (message) {
      case OutputMessage():
        if (!_output.isClosed) _output.add(message.bytes);
        lastOffset = message.nextOffset;
        _acknowledge();
      case ScreenMessage():
        // Ahead of the output that follows it, so the terminal is rebuilt
        // before those bytes land — and again for a pane that fell behind.
        if (!_output.isClosed) _output.add(message.bytes);
        lastOffset = message.offset;
        _ackedOffset = message.offset;
      case ExitedMessage():
        if (!_exit.isCompleted) {
          _exit.complete(
            HostSessionEnd(message.exitCode, message.reason, message.observedAt),
          );
        }
      case PresenceMessage():
        final presence = HostPresence(
          holder: message.holder,
          viewers: message.viewers,
          sizedFor: message.sizedFor,
          columns: message.columns,
          rows: message.rows,
          me: _link.clientId,
        );
        _lastPresence = presence;
        if (!_presence.isClosed) _presence.add(presence);
      case ErrorMessage(:final code, :final message):
        // A refused keystroke is shown by the presence cover, not typed
        // into the screen once per key.
        if (code == ProtocolErrorCode.writeRefused &&
            _lastPresence?.heldElsewhere == true) {
          if (!_refused.isClosed) _refused.add(null);
          break;
        }
        if (!_notices.isClosed) _notices.add(message);
      default:
        break;
    }
  }

  /// Tells the host how far this pane has rendered, so it sends more.
  void _acknowledge() {
    if (!_link.acksOutput) return;
    if (lastOffset - _ackedOffset >= _ackEvery) {
      _sendAck();
      return;
    }
    _ackTimer ??= Timer(const Duration(milliseconds: 30), _sendAck);
  }

  void _sendAck() {
    _ackTimer?.cancel();
    _ackTimer = null;
    if (_closed || lastOffset <= _ackedOffset) return;
    _ackedOffset = lastOffset;
    _link.send(OutputAckMessage(_sessionRef, lastOffset));
  }

  /// The ref's stream ended: the link went, or the attachment was let go.
  void _refEnded() => _fail(_link.closeReason ?? 'The host channel closed.');

  void _fail(String reason) {
    if (_closed) return;
    _closed = true;
    _ackTimer?.cancel();
    if (!_output.isClosed) _output.close();
    if (!_notices.isClosed) _notices.close();
    if (!_presence.isClosed) _presence.close();
    if (!_refused.isClosed) _refused.close();
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
