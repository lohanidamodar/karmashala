/// Canonical `type` strings for normalized session events.
///
/// Lifecycle events (`session.*`) are emitted by the session engine; content
/// events (`message.*`, `agent.*`, `tool.*`) originate from an `AgentChatProtocol`.
/// Keeping them centralized lets the UI and the future mobile app rely on a
/// stable vocabulary regardless of which agent produced them.
class SessionEventTypes {
  const SessionEventTypes._();

  static const sessionStarted = 'session.started';
  static const sessionCompleted = 'session.completed';
  static const sessionFailed = 'session.failed';
  static const sessionCancelled = 'session.cancelled';

  static const userMessage = 'message.user';
  static const agentMessage = 'message.agent';
  static const agentStatus = 'agent.status';
  static const error = 'session.error';

  /// One tool invocation by the agent. Payload: `name`, `input`, and — where the
  /// protocol carries one — `toolUseId`.
  ///
  /// This was a bare string literal in two adapters while every sibling went
  /// through this class.
  static const toolCall = 'tool.call';

  /// The result of a [toolCall], correlated back to it by `toolUseId`.
  ///
  /// **Not emitted yet.** It is named here because it is the missing half of the
  /// pair: without a result event there is no way to know a tool call finished,
  /// which is why an in-agent subagent (Claude Code's `Task` tool, which arrives
  /// as an ordinary [toolCall]) would show as running forever. Whoever adds
  /// subagent rendering needs this, and needs the correlation id below to be
  /// carried through first.
  static const toolResult = 'tool.result';
}

/// Payload key holding the protocol's own id for a tool invocation.
///
/// The correlation key between a [SessionEventTypes.toolCall] and its
/// [SessionEventTypes.toolResult]. Claude Code puts it on the `tool_use` block
/// as `id` and echoes it on the matching `tool_result` as `tool_use_id`.
const String kToolUseIdKey = 'toolUseId';

/// The tool names Claude Code uses to launch an **in-agent subagent**.
///
/// Worth naming because there are two unrelated things called a subagent and
/// conflating them would be a real bug:
///
/// * this one lives *inside* a single session, arrives as a tool call, and never
///   creates a session row — so the spawn-depth cap must **not** apply to it;
/// * a session an agent creates through the MCP bridge is a separate row with a
///   `parent_session_id`, and the cap **must** apply to that (`SessionDepth`).
///
/// **Two names, and the second one is the one that ships.** Counted over the
/// owner's whole Claude Code store on 2026-09-08: **650 `Agent` calls and zero
/// `Task` calls**. The tool was renamed, and while this held `Task` alone
/// nothing keyed on it fired — a subagent never read as one in the activity
/// strip, and `_attachSubagents` never hung a delegate's turns under the row
/// that spawned it, because the `subagents/*.meta.json` on disk join on the
/// `tool_use.id` of an **`Agent`** call (verified against
/// `toolu_01QzeLLf11K6C9wLFJMKivkE`, agent type `Explore`, spawn depth 2).
///
/// Both are kept: an older CLI still writes `Task`, and a store is read long
/// after the binary that wrote it was replaced.
const Set<String> kSubagentToolNames = {'Agent', 'Task'};

/// The name a *new* subagent row is written with — the one the installed CLI
/// uses. Read [kSubagentToolNames] to recognise one.
const String kSubagentToolName = 'Agent';

/// Whether [toolName] is one of the tools that spawns an in-agent subagent.
bool isSubagentToolName(String toolName) =>
    kSubagentToolNames.contains(toolName);
