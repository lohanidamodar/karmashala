/// The coding-agent CLIs Chitragupta speaks a **protocol** for.
///
/// This is not agent identity — that is `AgentDescriptor.id`, a plain string, so
/// a new agent needs no member here. This enum answers a narrower question:
/// which agents have a hand-written `AgentAdapter`. The set is closed by code
/// because a protocol parser cannot be data; everything else about an agent can.
///
/// Read in exactly one place, `agentAdapterResolverProvider`, to pick the richer
/// adapter. An agent without a member here still gets discovered, persisted,
/// listed and opened — with `GenericAgentAdapter` and no rich chat.
enum AgentKind {
  /// Anthropic Claude Code (stream-json protocol).
  claudeCode,

  /// Codex CLI (app-server protocol).
  codex,

  /// Antigravity CLI (compatibility adapter).
  antigravity,
}
