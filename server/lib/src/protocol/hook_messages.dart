part of 'messages.dart';

/// One callback an agent's installed hook posted to the host, as received.
class AgentHookEvent {
  const AgentHookEvent({
    required this.agent,
    required this.event,
    required this.receivedAt,
    required this.body,
    this.sessionHeader,
  });

  final String agent;
  final String event;

  /// The pane's `KARMASHALA_SESSION_ID`, or null when the hook sent none.
  final String? sessionHeader;
  final DateTime receivedAt;

  /// The hook's own JSON payload.
  final Map<String, Object?> body;

  Map<String, Object?> toJson() => {
    'agent': agent,
    'event': event,
    if (sessionHeader != null) 'sessionHeader': sessionHeader,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'body': body,
  };

  static AgentHookEvent fromJson(Object? json) {
    final map = _object(json, 'hook');
    return AgentHookEvent(
      agent: _required<String>(map, 'agent'),
      event: _required<String>(map, 'event'),
      sessionHeader: _optional<String>(map, 'sessionHeader'),
      receivedAt: _time(map, 'receivedAt') ?? _missing('receivedAt'),
      body: _object(map['body'], 'hook body'),
    );
  }

  @override
  String toString() =>
      'AgentHookEvent($agent $event'
      '${sessionHeader == null ? '' : ' pane $sessionHeader'})';
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

/// client → host: a hook the client took itself — on its own `/agent-hook`
/// route, or from a spool — for the server's checkpoint recorder. The agent
/// was answered long before this arrives, so it is never held; a
/// `PreToolUse` in it marks its turn's before-turn checkpoints unverified.
class HookForwardMessage extends HostMessage {
  const HookForwardMessage(this.hook);
  final AgentHookEvent hook;

  @override
  Frame toFrame() => Frame(
    MessageType.hookForward,
    0,
    (WireWriter()..str(jsonEncode(hook.toJson()))).take(),
  );

  static HookForwardMessage decode(Frame frame) => HookForwardMessage(
    AgentHookEvent.fromJson(_decodeJson(WireReader(frame.payload).str())),
  );
}
