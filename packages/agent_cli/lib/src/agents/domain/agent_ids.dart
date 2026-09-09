/// The descriptor ids of the agents shipped in [builtInAgentDescriptors].
///
/// Agent identity is a plain `String` — the id of an [AgentDescriptor] — so a
/// new agent needs no enum member. These constants exist only so the handful of
/// call sites that genuinely mean *one specific built-in agent* (Claude account
/// switching, the usage endpoints, the launcher chat) say so by name instead of
/// repeating a literal.
abstract final class AgentIds {
  static const String claudeCode = 'claudeCode';
  static const String codex = 'codex';
  static const String antigravity = 'antigravity';

  /// The three shipped ids, in registry order.
  static const List<String> builtIn = [claudeCode, codex, antigravity];
}
