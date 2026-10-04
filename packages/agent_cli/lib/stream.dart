/// **Mode 2 — a conversation over the CLI's own stream protocol.**
///
/// A process that stays up and is written to and read from: an adapter's
/// `AgentChatProtocol` starts one, `StreamingAgentSession` carries the transport, and each agent's
/// adapter translates its wire format into the one `AgentEvent` vocabulary.
///
/// The adapters take a `RunnerResolver` — `CommandRunner Function(String
/// environmentId)` — and nothing else; composing that is the host's job.
library;

export 'src/agents/antigravity/antigravity_chat_protocol.dart';
export 'src/agents/claude_code/claude_code_chat_protocol.dart';
export 'src/agents/codex/codex_chat_protocol.dart';
export 'src/agents/adapter/fake_chat_protocol.dart';
export 'src/agents/adapter/generic_chat_protocol.dart';
export 'src/agents/data/resume_conflict_source.dart';
export 'src/agents/data/streaming_agent_session.dart';
export 'src/agents/adapter/agent_chat_protocol.dart';
export 'src/sessions/delegation_calls.dart';
export 'src/sessions/session_event_types.dart';
export 'src/sessions/tool_activity.dart';
