/// The model a session runs on, and whether that was its own decision. Two
/// states, for [SessionPermission]'s reason; a null [modelId] is a third.
class SessionModel {
  const SessionModel({required this.modelId, required this.chosen});

  /// The CLI's own id for the model, or null for "the agent's own default".
  final String? modelId;

  /// Whether [modelId] was chosen **for this session**, rather than read from
  /// the per-agent default in Settings.
  final bool chosen;

  /// Whether this session tracks the default live.
  bool get followsDefault => !chosen;
}

/// **The** precedence rule for models: a session's own choice outranks the
/// per-agent default, which outranks the agent's own. Null is still an answer.
SessionModel resolveSessionModel({
  required String? sessionModelId,
  required String? defaultModelId,
}) {
  // Empty is not a choice: a row could only hold `''` from a caller that meant
  // null, and reading it back would put an empty `--model` on a command line.
  if (sessionModelId != null && sessionModelId.isNotEmpty) {
    return SessionModel(modelId: sessionModelId, chosen: true);
  }
  return SessionModel(
    modelId: defaultModelId == null || defaultModelId.isEmpty
        ? null
        : defaultModelId,
    chosen: false,
  );
}
