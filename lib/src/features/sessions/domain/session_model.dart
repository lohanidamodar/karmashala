/// The model a session runs on, and whether that was its own decision.
///
/// Two states, not one value, for [SessionPermission]'s reason: a session
/// carrying an explicit model and one following the per-agent default can name
/// the same model today and must behave differently tomorrow.
///
/// [modelId] being null is a third thing again, and not an error: no model is
/// named at all, so no flag is passed and the agent starts on whatever it is
/// configured to use. Every session in the database was in that state before
/// this feature, so it has to be expressible.
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
/// per-agent default, which outranks the agent's own default.
///
/// [defaultModelId] has one supplier, `SessionLauncher.defaultModelFor`, and
/// null is still an answer and still the shipped one — an agent with no row in
/// `Settings.defaultModels` is "let the agent choose", and no model flag goes.
///
/// The same shape as `resolveSessionPermission`, deliberately, so the chip, the
/// launch and the next resume read one statement of the rule instead of three
/// agreeing ones. Unlike permissions there is no `SessionPurpose` split: a
/// model does not change meaning between a new conversation and a continued one.
SessionModel resolveSessionModel({
  required String? sessionModelId,
  required String? defaultModelId,
}) {
  // Empty is not a choice. A row could only hold `''` by way of a caller that
  // meant null, and reading it back would put an empty `--model` on a command
  // line.
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
