/// The model a session runs on, and whether that was its own decision.
///
/// Two states, not one value, for [SessionPermission]'s reason: a session
/// carrying an explicit model and a session following the per-agent default can
/// name the same model today and must behave differently tomorrow — the first
/// must not move when the default changes, the second must.
///
/// [modelId] being null is a third thing again, and it is not an error: it is
/// "no model is named at all", which means Karmashala passes no model flag and
/// the agent starts on whatever it is configured to use. That is the state
/// every session in the database was in before this feature, so it has to be
/// expressible rather than papered over with a made-up default.
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
/// [defaultModelId] has one supplier: `SessionLauncher.defaultModelFor`, which
/// reads `Settings.defaultModels`. It was written against a supplier that
/// answered null, on the argument that a setting added later should change one
/// supplier rather than this statement of the rule; Settings → Agents → Default
/// model is that setting, and it arrived without a line here changing. Null is
/// still an answer and still the shipped one: an agent with no row in that map
/// is "let the agent choose", and no model flag is passed.
///
/// The same shape as `resolveSessionPermission`, deliberately, so the chip, the
/// launch path and the next resume read one statement of the rule instead of
/// three agreeing ones — which is exactly how the permission resolution came to
/// disagree with itself across eight call sites.
///
/// Unlike permissions there is no `SessionPurpose` split. A permission default
/// differs between a new conversation and one being continued because the risk
/// does; a model does not change meaning between the two.
SessionModel resolveSessionModel({
  required String? sessionModelId,
  required String? defaultModelId,
}) {
  // Empty is not a choice. A row could only hold `''` by way of a caller that
  // meant null, and reading it back as a chosen model would put an empty
  // `--model` on a command line.
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
