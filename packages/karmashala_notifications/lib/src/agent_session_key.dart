import 'attention_json.dart';

/// Identifies one agent session as the status pipeline does: the agent's
/// registry id plus the CLI's own session id, never the workspace row id.
class AgentSessionKey {
  const AgentSessionKey(this.agentId, this.sessionId);

  final String agentId;
  final String sessionId;

  @override
  bool operator ==(Object other) =>
      other is AgentSessionKey &&
      other.agentId == agentId &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(agentId, sessionId);

  @override
  String toString() => '$agentId/$sessionId';

  Map<String, Object?> toJson() => {'agentId': agentId, 'sessionId': sessionId};

  static AgentSessionKey fromJson(Object? json) {
    final map = attentionObject(json, 'session key');
    return AgentSessionKey(
      attentionString(map, 'agentId'),
      attentionString(map, 'sessionId'),
    );
  }
}
