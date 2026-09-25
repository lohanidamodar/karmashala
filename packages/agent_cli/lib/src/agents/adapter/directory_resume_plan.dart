/// What to put on a command line to continue an existing session of an agent
/// whose store records the last conversation per directory.
sealed class DirectoryResumePlan {
  const DirectoryResumePlan();

  /// The arguments this plan contributes. Empty for a refusal.
  List<String> get arguments;
}

/// The conversation is known and named outright.
final class DirectoryResumeById extends DirectoryResumePlan {
  const DirectoryResumeById(this.conversationId, this.arguments);

  final String conversationId;

  @override
  final List<String> arguments;
}

/// No id was recorded against this session, but the store names the
/// conversation the directory last used, so it can be resumed by name.
///
/// **This is where `--continue` would go, and deliberately does not.** `agy -c`
/// continues "the most recent conversation", and the evidence that "most
/// recent" is scoped to the working directory is a symbol chain in the 1.1.22
/// binary — `entrypoints.resolveContinuedConversationID` →
/// `store.Manager.GetLastConversation` → `cache/last_conversations.json`, a
/// `{directory: conversation id}` map — rather than an observed run. That is
/// good evidence and it is not proof.
///
/// Naming the conversation outright needs no such assumption: it reaches the
/// same conversation if the scope is what it appears to be, and if it is not,
/// it still reaches the one the app just told the user it would. A flag that
/// quietly opens a different conversation than the one named is precisely the
/// failure this whole module exists to avoid, and there is no upside to
/// accepting it when the id is in hand.
///
/// `AgentContinueSupport` stays declared on the descriptor because the flag is
/// a real fact about the CLI, and because it is what says this agent has a
/// "latest conversation here" notion at all — which is the thing being fallen
/// back on. It is simply never the better way to say it.
final class DirectoryContinueLatest extends DirectoryResumePlan {
  const DirectoryContinueLatest({
    required this.conversationId,
    required this.arguments,
  });

  /// The conversation the store records for this directory: what is about to be
  /// reopened, and what the app should say before reopening it.
  final String conversationId;

  @override
  final List<String> arguments;
}

/// Nothing truthful can be put on the command line. [reason] is shown.
final class DirectoryResumeRefused extends DirectoryResumePlan {
  const DirectoryResumeRefused(this.reason);

  final String reason;

  @override
  List<String> get arguments => const [];
}
