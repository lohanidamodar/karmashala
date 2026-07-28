import '../../environments/domain/environment_path.dart';
import '../../settings/domain/permission_mode.dart';
import 'agent_installation.dart';
import 'agent_kind.dart';

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
    this.permissionMode = PermissionMode.ask,
    this.resumeSessionId,
    this.mcpConfigPath,
    this.allowedTools = const [],
  });

  /// Directory the agent runs in (the repo or a worktree), bound to its
  /// environment.
  final EnvironmentPath workingDirectory;

  /// The specific agent installation to launch.
  final AgentInstallation installation;

  /// How much the agent may do without prompting (mapped to CLI flags). Defaults
  /// to the safe [PermissionMode.ask].
  final PermissionMode permissionMode;

  /// When resuming an existing CLI session, its id; otherwise `null`.
  final String? resumeSessionId;

  /// Path to an MCP config file (`--mcp-config`) exposing extra tools to the
  /// agent, or `null` for none. Used by the launcher chat to give the agent
  /// Chitragupta's own tools.
  final String? mcpConfigPath;

  /// Tool names to pre-approve (`--allowedTools`) so the agent can call them
  /// without an interactive prompt (there is no TTY in stream-json mode).
  final List<String> allowedTools;
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
  /// The agent kind this adapter handles.
  AgentKind get kind;

  /// Starts a run for [launch], returning a live [AgentSession].
  AgentSession start(AgentLaunch launch);
}
