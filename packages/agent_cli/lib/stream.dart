/// **Mode 2 — a conversation over the CLI's own stream protocol.**
///
/// A process that stays up and is written to and read from: `AgentAdapter`
/// starts one, `StreamingAgentSession` carries the transport, and each agent's
/// adapter translates its wire format into the one `AgentEvent` vocabulary.
///
/// The adapters take a `RunnerResolver` — `CommandRunner Function(String
/// environmentId)` — and nothing else; composing that is the host's job
/// (docs/PACKAGE_SPLIT.md §3).
library;

export 'src/agents/data/antigravity_adapter.dart';
export 'src/agents/data/claude_code_adapter.dart';
export 'src/agents/data/codex_adapter.dart';
export 'src/agents/data/fake_agent_adapter.dart';
export 'src/agents/data/generic_agent_adapter.dart';
export 'src/agents/data/resume_conflict_source.dart';
export 'src/agents/data/streaming_agent_session.dart';
export 'src/agents/domain/agent_adapter.dart';
export 'src/sessions/session_event_types.dart';
export 'src/sessions/tool_activity.dart';
