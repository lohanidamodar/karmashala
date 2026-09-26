part of 'messages.dart';

/// One callback an agent's installed hook posted to the host, as received.
class AgentHookEvent {
  const AgentHookEvent({
    required this.agent,
    required this.event,
    required this.receivedAt,
    required this.body,
    this.sessionHeader,
    this.holdId,
  });

  final String agent;
  final String event;

  /// The pane's `KARMASHALA_SESSION_ID`, or null when the hook sent none.
  final String? sessionHeader;
  final DateTime receivedAt;

  /// The hook's own JSON payload.
  final Map<String, Object?> body;

  /// Set only on a live `hook` frame whose agent the host is holding: a
  /// watcher answers it with [HookReplyMessage] once it has done its work. A
  /// hook without one was answered at once — a held-kind hook without one had
  /// nobody watching to wait for, and the snapshot never carries one.
  final int? holdId;

  /// This hook as relayed while its agent waits on [id].
  AgentHookEvent heldAs(int id) => AgentHookEvent(
    agent: agent,
    event: event,
    receivedAt: receivedAt,
    body: body,
    sessionHeader: sessionHeader,
    holdId: id,
  );

  /// This hook as kept for the snapshot: its hold is over by the time anyone
  /// reads it there.
  AgentHookEvent get unheld => holdId == null
      ? this
      : AgentHookEvent(
          agent: agent,
          event: event,
          receivedAt: receivedAt,
          body: body,
          sessionHeader: sessionHeader,
        );

  Map<String, Object?> toJson() => {
    'agent': agent,
    'event': event,
    if (sessionHeader != null) 'sessionHeader': sessionHeader,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'body': body,
    if (holdId != null) 'holdId': holdId,
  };

  static AgentHookEvent fromJson(Object? json) {
    final map = _object(json, 'hook');
    return AgentHookEvent(
      agent: _required<String>(map, 'agent'),
      event: _required<String>(map, 'event'),
      sessionHeader: _optional<String>(map, 'sessionHeader'),
      receivedAt: _time(map, 'receivedAt') ?? _missing('receivedAt'),
      body: _object(map['body'], 'hook body'),
      holdId: _optional<int>(map, 'holdId'),
    );
  }

  @override
  String toString() =>
      'AgentHookEvent($agent $event'
      '${sessionHeader == null ? '' : ' pane $sessionHeader'}'
      '${holdId == null ? '' : ' held $holdId'})';
}

/// host → client: one hook, pushed to every watching connection.
class HookMessage extends HostMessage {
  const HookMessage(this.hook);
  final AgentHookEvent hook;

  @override
  Frame toFrame() => Frame(
    MessageType.hook,
    0,
    (WireWriter()..str(jsonEncode(hook.toJson()))).take(),
  );

  static HookMessage decode(Frame frame) => HookMessage(
    AgentHookEvent.fromJson(_decodeJson(WireReader(frame.payload).str())),
  );
}

/// client → host: the watcher has done what the hook held under [holdId]
/// waited for, so the agent may go on. The first reply releases it; a late or
/// repeated one is ignored.
class HookReplyMessage extends HostMessage {
  const HookReplyMessage(this.holdId);
  final int holdId;

  @override
  Frame toFrame() => Frame(
    MessageType.hookReply,
    0,
    (WireWriter()..str(jsonEncode({'holdId': holdId}))).take(),
  );

  static HookReplyMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'hook reply',
    );
    return HookReplyMessage(_required<int>(map, 'holdId'));
  }
}
