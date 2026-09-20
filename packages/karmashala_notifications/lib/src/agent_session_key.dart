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
}
