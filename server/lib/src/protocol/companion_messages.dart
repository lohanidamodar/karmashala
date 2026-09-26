part of 'messages.dart';

// The companion in the daemon (protocol 4): the host serves paired phones, and
// forwards to the connected app what only the app can answer. JSON inside a
// length-prefixed string, like the lifecycle feed and the MCP relay.

/// client → host: this connection is the desktop app, which the host
/// forwards companion calls to, and its embedded relay listens at
/// [localRelayUrl] (null: it runs none). Sent on every link and again when the
/// embedded relay moves. How phones are served is not here: that is the
/// server's `server.json`, changed with `server.config.set`.
class CompanionAttachMessage extends HostMessage {
  const CompanionAttachMessage({this.localRelayUrl});

  final String? localRelayUrl;

  @override
  Frame toFrame() => Frame(
    MessageType.companionAttach,
    0,
    (WireWriter()..str(jsonEncode({'localRelayUrl': ?localRelayUrl}))).take(),
  );

  static CompanionAttachMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'companion attach',
    );
    return CompanionAttachMessage(
      localRelayUrl: _optional<String>(map, 'localRelayUrl'),
    );
  }
}

/// host → client: answer [method] (a `CompanionMethod` wire name) with
/// [arguments], for a phone that asked, and reply to [callId].
class CompanionCallMessage extends HostMessage {
  const CompanionCallMessage({
    required this.callId,
    required this.method,
    required this.arguments,
  });

  final int callId;
  final String method;
  final Map<String, Object?> arguments;

  @override
  Frame toFrame() => Frame(
    MessageType.companionCall,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'method': method,
            'arguments': arguments,
          }),
        ))
        .take(),
  );

  static CompanionCallMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'companion call',
    );
    return CompanionCallMessage(
      callId: _required<int>(map, 'callId'),
      method: _required<String>(map, 'method'),
      arguments: _object(map['arguments'], 'arguments'),
    );
  }
}

/// client → host: how [callId] ended — [result] when it did, else the
/// companion error [code] (an `ErrorCode` wire word) and [message] the phone is
/// shown.
class CompanionResultMessage extends HostMessage {
  const CompanionResultMessage.success(
    this.callId,
    Map<String, Object?> this.result,
  ) : code = null,
      message = null;

  const CompanionResultMessage.failure(
    this.callId, {
    required String this.code,
    required String this.message,
  }) : result = null;

  final int callId;
  final Map<String, Object?>? result;
  final String? code;
  final String? message;

  bool get ok => code == null;

  @override
  Frame toFrame() => Frame(
    MessageType.companionResult,
    0,
    (WireWriter()..str(
          jsonEncode({
            'callId': callId,
            'ok': ok,
            if (ok) 'result': result else ...{'code': code, 'message': message},
          }),
        ))
        .take(),
  );

  static CompanionResultMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'companion result',
    );
    final callId = _required<int>(map, 'callId');
    return _required<bool>(map, 'ok')
        ? CompanionResultMessage.success(
            callId,
            _object(map['result'], 'result'),
          )
        : CompanionResultMessage.failure(
            callId,
            code: _required<String>(map, 'code'),
            message: _required<String>(map, 'message'),
          );
  }
}

/// What the app tells the host's companion about the desktop.
enum CompanionNoticeKind {
  /// Something about sessions moved: every live phone re-reads its
  /// subscriptions.
  sessionsMoved,

  /// [CompanionNoticeMessage.sessionId] started waiting for approval.
  approvalRequested,

  /// A new inbox item worth a push for phones with no live link.
  attention,

  /// A paired-device row was renamed, re-granted or revoked in the app.
  devicesChanged,

  /// The pairing dialog closed: the window's secret dies with it.
  pairingCancelled,
}

/// client → host: one [CompanionNoticeKind], with the fields it needs.
class CompanionNoticeMessage extends HostMessage {
  const CompanionNoticeMessage(
    this.kind, {
    this.sessionId,
    this.title,
    this.attention,
    this.detail,
  });

  final CompanionNoticeKind kind;
  final String? sessionId;

  /// For [CompanionNoticeKind.attention]: the push's title and kind word.
  final String? title;
  final String? attention;
  final String? detail;

  @override
  Frame toFrame() => Frame(
    MessageType.companionNotice,
    0,
    (WireWriter()..str(
          jsonEncode({
            'kind': kind.name,
            'sessionId': ?sessionId,
            'title': ?title,
            'attention': ?attention,
            'detail': ?detail,
          }),
        ))
        .take(),
  );

  static CompanionNoticeMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'companion notice',
    );
    final name = _required<String>(map, 'kind');
    final kind = CompanionNoticeKind.values.where((k) => k.name == name);
    if (kind.isEmpty) throw WireFormatException('unknown notice "$name"');
    return CompanionNoticeMessage(
      kind.single,
      sessionId: _optional<String>(map, 'sessionId'),
      title: _optional<String>(map, 'title'),
      attention: _optional<String>(map, 'attention'),
      detail: _optional<String>(map, 'detail'),
    );
  }
}

/// What the host's companion tells the app.
enum CompanionEventKind {
  /// Paired-device rows moved — paired, seen, a generation advanced, a push
  /// token registered — so lists re-read.
  devicesChanged,

  /// The pairing window [CompanionEventMessage.requestId] opened is over:
  /// [CompanionEventMessage.deviceId] paired, or it ended with
  /// [CompanionEventMessage.error].
  pairingEnded,
}

/// host → client: one [CompanionEventKind].
class CompanionEventMessage extends HostMessage {
  const CompanionEventMessage(
    this.kind, {
    this.requestId,
    this.deviceId,
    this.error,
  });

  final CompanionEventKind kind;
  final int? requestId;
  final String? deviceId;
  final String? error;

  @override
  Frame toFrame() => Frame(
    MessageType.companionEvent,
    0,
    (WireWriter()..str(
          jsonEncode({
            'kind': kind.name,
            'requestId': ?requestId,
            'deviceId': ?deviceId,
            'error': ?error,
          }),
        ))
        .take(),
  );

  static CompanionEventMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'companion event',
    );
    final name = _required<String>(map, 'kind');
    final kind = CompanionEventKind.values.where((k) => k.name == name);
    if (kind.isEmpty) throw WireFormatException('unknown event "$name"');
    return CompanionEventMessage(
      kind.single,
      requestId: _optional<int>(map, 'requestId'),
      deviceId: _optional<String>(map, 'deviceId'),
      error: _optional<String>(map, 'error'),
    );
  }
}
