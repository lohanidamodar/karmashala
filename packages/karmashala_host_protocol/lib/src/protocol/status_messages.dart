part of 'messages.dart';

// Agent status in the daemon (protocol 7): the host keeps what the agent in
// each session it holds is doing — from the hooks it takes and the screens it
// holds — and answers the prompts those agents open. The status itself is the
// JSON `karmashala_agent_status` writes (`HostedAgentStatus.toJson`); this
// file carries it and knows nothing of agents.

/// host → client: what the agent in the session row [sessionId] is doing now,
/// or — [status] null — that the host has stopped keeping it (its process
/// ended, or its row is gone).
class AgentStatusMessage extends HostMessage {
  const AgentStatusMessage({required this.sessionId, this.status});

  final String sessionId;

  /// `HostedAgentStatus.toJson`, or null when the status is no longer kept.
  final Map<String, Object?>? status;

  @override
  Frame toFrame() => Frame(
    MessageType.agentStatus,
    0,
    (WireWriter()..str(jsonEncode({'sessionId': sessionId, 'status': status})))
        .take(),
  );

  static AgentStatusMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'agent status',
    );
    final status = map['status'];
    return AgentStatusMessage(
      sessionId: _required<String>(map, 'sessionId'),
      status: status == null ? null : _object(status, 'agent status body'),
    );
  }
}

/// client → host: answer a prompt the agent in a session the host holds has
/// open — `PromptAnswerRequest.toJson` — and reply with [PromptAnsweredMessage]
/// under [requestId].
class PromptAnswerMessage extends HostMessage {
  const PromptAnswerMessage({required this.requestId, required this.request});

  final int requestId;
  final Map<String, Object?> request;

  @override
  Frame toFrame() => Frame(
    MessageType.promptAnswer,
    0,
    (WireWriter()
          ..str(jsonEncode({'requestId': requestId, 'request': request})))
        .take(),
  );

  static PromptAnswerMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'prompt answer',
    );
    return PromptAnswerMessage(
      requestId: _required<int>(map, 'requestId'),
      request: _object(map['request'], 'prompt answer request'),
    );
  }
}

/// Why a prompt answer was refused, so a client can word it as its own
/// surface does.
enum PromptRefusalKind {
  /// Nothing was chosen: no prompt open, the prompt changed, no such option.
  refused,

  /// No such session.
  notFound,

  /// The session has no live terminal to answer in.
  noTerminal,
}

/// host → client: how the [PromptAnswerMessage] under [requestId] ended —
/// what was chosen and what it does, or why nothing was.
class PromptAnsweredMessage extends HostMessage {
  const PromptAnsweredMessage.answered({
    required this.requestId,
    required String this.answered,
    required String this.effect,
  }) : refusal = null,
       message = null;

  const PromptAnsweredMessage.refused({
    required this.requestId,
    required PromptRefusalKind this.refusal,
    required String this.message,
  }) : answered = null,
       effect = null;

  final int requestId;
  final String? answered;
  final String? effect;
  final PromptRefusalKind? refusal;
  final String? message;

  bool get ok => refusal == null;

  @override
  Frame toFrame() => Frame(
    MessageType.promptAnswered,
    0,
    (WireWriter()..str(
          jsonEncode({
            'requestId': requestId,
            'answered': ?answered,
            'effect': ?effect,
            'refusal': ?refusal?.name,
            'message': ?message,
          }),
        ))
        .take(),
  );

  static PromptAnsweredMessage decode(Frame frame) {
    final map = _object(
      _decodeJson(WireReader(frame.payload).str()),
      'prompt answered',
    );
    final requestId = _required<int>(map, 'requestId');
    final refusal = _optional<String>(map, 'refusal');
    if (refusal == null) {
      return PromptAnsweredMessage.answered(
        requestId: requestId,
        answered: _required<String>(map, 'answered'),
        effect: _required<String>(map, 'effect'),
      );
    }
    final kind = PromptRefusalKind.values.where((k) => k.name == refusal);
    return PromptAnsweredMessage.refused(
      requestId: requestId,
      refusal: kind.isEmpty ? PromptRefusalKind.refused : kind.single,
      message: _optional<String>(map, 'message') ?? 'refused',
    );
  }
}
