/// The line formats `readCliTranscript` knows how to parse.
///
/// A format, not an agent: an agent whose CLI writes one of these declares it
/// in its `AgentTranscripts` and is read the same way. Only a genuinely new
/// line format is a new value here and a new parser beside it.
enum TranscriptDialect {
  /// Claude Code's per-project JSONL: `type` user/assistant/system records,
  /// `tool_use` and `tool_result` content blocks, subagent side files. The
  /// least-wrong guess for a transcript nobody declared.
  claudeJsonl,

  /// Codex's rollout JSONL: `payload`-wrapped response items and events.
  codexRollout,

  /// Antigravity's plain JSONL transcript, written beside its store on some
  /// installs: `created_at`-stamped message records.
  antigravityJsonl,
}
