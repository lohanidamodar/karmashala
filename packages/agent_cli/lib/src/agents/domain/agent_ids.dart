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

  /// The three shipped ids, in registry order.
  static const List<String> builtIn = [claudeCode, codex, antigravity];
}
