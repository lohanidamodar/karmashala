/// What an agent's own undo holds for a session, read from its transcript.
class AgentRewindPoints {
  const AgentRewindPoints({
    required this.agentId,
    required this.checkpoints,
    required this.withFileEdits,
    this.latest,
  });

  final String agentId;

  /// Prompts the agent can rewind to.
  final int checkpoints;

  /// Of those, the ones whose files it backed up — its "Restore code" rows.
  final int withFileEdits;

  final DateTime? latest;
}
