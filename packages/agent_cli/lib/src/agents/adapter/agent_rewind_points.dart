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

  /// The form `sessions.rewindPoints` carries from the server that read the
  /// transcript. [latest] is ISO-8601 UTC.
  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'checkpoints': checkpoints,
    'withFileEdits': withFileEdits,
    'latest': ?latest?.toUtc().toIso8601String(),
  };

  /// Throws on a value out of shape; an unknown field is ignored.
  static AgentRewindPoints fromJson(Map<String, Object?> json) {
    final latest = json['latest'];
    return AgentRewindPoints(
      agentId: json['agentId']! as String,
      checkpoints: json['checkpoints']! as int,
      withFileEdits: json['withFileEdits']! as int,
      latest: latest is String ? DateTime.tryParse(latest)?.toUtc() : null,
    );
  }
}
