/// The descriptor ids of the agents shipped in `builtInAgentAdapters`.
///
/// Agent identity is a plain `String` — the id of an [AgentDescriptor] — so a
/// new agent needs no enum member. These constants are for the code that
/// genuinely means *one specific built-in agent*: that agent's own folder under
/// `agents/<agent>/`, and tests. Everything else asks an `AgentAdapter` for a
/// capability instead — a branch on one of these outside its adapter is a bug,
/// and `agent_id_branch_guard_test.dart` fails on it.
abstract final class AgentIds {
  static const String claudeCode = 'claudeCode';
  static const String codex = 'codex';
  static const String antigravity = 'antigravity';

  /// The agents spoken to over the Agent Client Protocol (`agents/acp/`).
  static const String claudeAcp = 'claude-acp';
  static const String codexAcp = 'codex-acp';
  static const String geminiCli = 'gemini-cli';
  static const String grok = 'grok';

  /// The shipped ids, in registry order: the three terminal agents, then the
  /// four ACP ones.
  static const List<String> builtIn = [
    claudeCode,
    codex,
    antigravity,
    claudeAcp,
    codexAcp,
    geminiCli,
    grok,
  ];
}
