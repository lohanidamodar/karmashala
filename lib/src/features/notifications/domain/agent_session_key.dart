/// Identifies one agent session the way the status pipeline does: the agent's
/// registry id plus the CLI's own session id.
///
/// Deliberately not the workspace database id — a status report is keyed by
/// what the agent itself announces, and the same CLI session can be reached
/// through more than one workspace row.
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
