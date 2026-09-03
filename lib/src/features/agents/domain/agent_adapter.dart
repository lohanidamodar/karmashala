import '../../environments/domain/environment_path.dart';
import 'agent_installation.dart';
import 'agent_permission_support.dart';

/// A normalized event emitted by an agent, before it is persisted.
///
/// Protocol-agnostic: each `AgentAdapter` translates its agent's wire protocol
/// into these. [type] uses the `SessionEventTypes` vocabulary; [data] is a
/// JSON-encodable map serialized into a [SessionEvent] by the engine.
class AgentEvent {
  const AgentEvent(this.type, [this.data = const {}]);

  final String type;
  final Map<String, Object?> data;

  @override
  String toString() => 'AgentEvent($type, $data)';
}

/// Everything an adapter needs to launch a run.
class AgentLaunch {
  const AgentLaunch({
    required this.workingDirectory,
    required this.installation,
    this.permission = ResolvedPermission.none,
    this.resumeSessionId,
    this.mcpConfigPath,
    this.appendSystemPrompt,
  });

  /// Directory the agent runs in (the repo or a worktree), bound to its
  /// environment.
  final EnvironmentPath workingDirectory;

  /// The specific agent installation to launch.
  final AgentInstallation installation;

  /// The mode this run launches under, already resolved into flags.
  ///
  /// Resolved by the caller, which holds the descriptor; the adapters are
  /// handed a launch and cannot look one up. Defaults to
  /// [ResolvedPermission.none] — no selection and no flags — which is what an
  /// agent whose modes have never been established gets.
  final ResolvedPermission permission;

  /// When resuming an existing CLI session, its id; otherwise `null`.
  final String? resumeSessionId;

  /// Path to an MCP config file (`--mcp-config`) exposing extra tools to the
  /// agent, or `null` for none.
  ///
  /// Nothing writes it yet — the pane launcher builds its own MCP flags from
  /// `AgentMcpSupport` and never goes through an adapter — so the engine path
  /// currently resumes a session without Karmashala's tools. Kept because
  /// `SessionMcpAccess.configPath` already produces exactly this value, which
  /// makes it a wiring gap rather than an invention.
  final String? mcpConfigPath;

  /// Extra text appended to the agent's system prompt
  /// (`--append-system-prompt`), or `null` for none.
  ///
  /// Also unwritten today. It is kept and `allowedTools` was not, because they
  /// are different kinds of thing: text on a system prompt asks the agent for
  /// something, while a pre-approved tool list stops the *user* being asked.
  /// See `LauncherMcp` for why nothing here pre-approves anything.
  final String? appendSystemPrompt;
}

/// A live run of an agent: a stream of normalized [AgentEvent]s, plus the ability
/// to send the user's messages and to stop.
abstract interface class AgentSession {
  /// Normalized events from the agent. The stream closing ends the run.
  Stream<AgentEvent> get events;

  /// Sends a user message to the agent.
  Future<void> send(String message);

  /// Stops the run and releases resources (closes [events]).
  Future<void> stop();
}

/// Encapsulates one agent's protocol. Implementations translate raw agent
/// traffic into normalized [AgentEvent]s (ADR 0003). Loop 6 ships only a fake;
/// real adapters arrive in Loops 7 (Codex), 8 (Claude Code) and 10 (Antigravity).
abstract interface class AgentAdapter {
  /// The `AgentDescriptor.id` of the agent this adapter handles.
  String get agentId;

  /// Starts a run for [launch], returning a live [AgentSession].
  AgentSession start(AgentLaunch launch);
}
