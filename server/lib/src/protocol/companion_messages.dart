part of 'messages.dart';

// The companion in the daemon (protocol 4). Since protocol 27 (slice 5c) the
// server answers every phone call itself, app or no app: nothing is
// forwarded (`companionCall` 0x21 and `companionResult` 0x22 are retired).
// Since protocol 29 the LAN relay is the server's own too (`companionAttach`
// 0x20, where the app's embedded relay listened, is retired). What stays on a
// client's link is the pairing window it opened and that window closing. JSON inside a
// length-prefixed string, like the lifecycle feed.

/// What a desktop tells the host's companion. Attention, approvals and
/// session lists are the server's own since slice 5c; only the pairing
/// dialog is the desktop's.
enum CompanionNoticeKind {
  /// The pairing dialog closed: the window's secret dies with it.
  pairingCancelled,
}

/// client → host: one [CompanionNoticeKind].
class CompanionNoticeMessage extends HostMessage {
  const CompanionNoticeMessage(this.kind);

  final CompanionNoticeKind kind;

  @override
  Frame toFrame() => Frame(
    MessageType.companionNotice,
    0,
    (WireWriter()..str(jsonEncode({'kind': kind.name}))).take(),
  );

  static CompanionNoticeMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'companion notice',
    );
    final name = _required<String>(map, 'kind');
    final kind = CompanionNoticeKind.values.where((k) => k.name == name);
    if (kind.isEmpty) throw WireFormatException('unknown notice "$name"');
    return CompanionNoticeMessage(kind.single);
  }
}

/// What the host's companion tells the app. Device rows it writes reach every
/// client on the data channel (`DeviceChanged`), not here.
enum CompanionEventKind {
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
