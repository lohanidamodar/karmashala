/// The coding-agent CLIs Chitragupta can manage.
///
/// Each kind speaks its own protocol, handled behind an `AgentAdapter` in later
/// loops. The same kind installed in two environments is two independent
/// installations.
enum AgentKind {
  /// Anthropic Claude Code (stream-json protocol).
  claudeCode,

  /// Codex CLI (app-server protocol).
  codex,

  /// Antigravity CLI (compatibility adapter).
  antigravity,
}
