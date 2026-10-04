import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/launch.dart';

/// **The one file in the daemon that reads `agent_cli`** — an agent's adapter
/// and its descriptor. It asks what an agent declares and never which agent it
/// is: no branch on an agent id belongs here or anywhere else in the host.
class DaemonAgents {
  const DaemonAgents([this._registry = AgentRegistry.builtIn]) : _now = null;

  /// Over a registry that changes while the server runs — the shipped agents
  /// plus the ACP agents a person adds — read at every question, so a session
  /// can start with an agent added a moment ago.
  const DaemonAgents.live(AgentRegistry Function() now)
    : _registry = AgentRegistry.builtIn,
      _now = now;

  final AgentRegistry _registry;
  final AgentRegistry Function()? _now;

  AgentRegistry get _current => _now?.call() ?? _registry;

  /// The registry as it is now: which agents are forms of one another.
  AgentRegistry get registry => _current;

  /// Everything agent-specific the daemon may ask, behind one boundary.
  AgentAdapter? adapterOf(String agentId) => _current.adapterFor(agentId);

  AgentDescriptor? descriptorOf(String agentId) =>
      adapterOf(agentId)?.descriptor;

  /// The mode [stored] names for [agentId]; null is the agent's declared
  /// default — the mode the unattended gate judged.
  PermissionSelection permissionOf(String agentId, String? stored) =>
      descriptorOf(agentId)?.launch.permission.resolveStored(stored) ??
      PermissionSelection.empty;

  /// Why [agentId] cannot be started unattended with [prompt] from here, or
  /// null when it can.
  String? launchRefusal(String agentId, String prompt) {
    final descriptor = descriptorOf(agentId);
    if (descriptor == null) {
      return 'this build does not know the agent "$agentId"';
    }
    if (prompt.trim().isNotEmpty && !descriptor.launch.acceptsPromptArgument) {
      return '${descriptor.displayName} takes no opening message on its '
          'command line, so the prompt would be dropped without a word';
    }
    return null;
  }

  /// Whether [agentId] reads its MCP server from a config file rather than a
  /// URL on its command line.
  bool mcpNeedsConfigFile(String agentId) =>
      descriptorOf(agentId)?.launch.mcp.needsConfigFile ?? false;

  /// The command line for session [sessionId] of [agentId]: a new
  /// conversation told [prompt], or — with [resumeConversationId] — that
  /// conversation continued; on [modelId] when one was chosen, pointed at
  /// Karmashala's tools by [mcpUrl] or [mcpConfigPath].
  List<String> sessionArguments({
    required String agentId,
    required String sessionId,
    required String? permissionMode,
    String? prompt,
    String? modelId,
    String? resumeConversationId,
    String? mcpUrl,
    String? mcpConfigPath,
  }) {
    final descriptor = descriptorOf(agentId);
    final assignsOwnId =
        descriptor?.launch.sessionIdAssignment.isSupported ?? false;
    return agentPaneArguments(
      descriptor,
      permissionOf(agentId, permissionMode),
      modelId: modelId,
      sessionId: assignsOwnId ? sessionId : null,
      resumeSessionId: resumeConversationId,
      prompt: prompt,
      mcpUrl: mcpUrl,
      mcpConfigPath: mcpConfigPath,
    );
  }

  /// What [agentId] is called where a person reads it.
  String nameOf(String agentId) =>
      descriptorOf(agentId)?.displayName ?? agentId;

  /// Whether [agentId] can be told to continue a conversation by id in a
  /// terminal — the resume capability a phone's Resume needs.
  bool resumesById(String agentId) =>
      descriptorOf(agentId)?.launch.interactiveResume.isSupported ?? false;

  /// Whether [agentId] permits a second process on a conversation one is
  /// already writing to. Unknown is no.
  bool allowsConcurrentResume(String agentId) =>
      descriptorOf(agentId)?.launch.allowsConcurrentResume ?? false;

  /// Whether a new session of [agentId] is started under the id Karmashala
  /// gives it, so the row can name its conversation from the start.
  bool assignsOwnSessionId(String agentId) =>
      descriptorOf(agentId)?.launch.sessionIdAssignment.isSupported ?? false;

  /// The view a new session of [agentId] opens in: chat where its store is
  /// one Karmashala reads, else the terminal.
  SessionView defaultView(String agentId) => defaultViewFor(adapterOf(agentId));

  /// Why [agentId], shown [screen] (its rows as text, oldest first), is not
  /// going to get on with the work until a person answers it — its first-run
  /// question about [directory] — or null when the screen shows no such
  /// question, or the agent declares none. Read, never answered.
  String? firstRunPromptOn(
    String agentId,
    List<String> screen, {
    required String directory,
  }) {
    final descriptor = descriptorOf(agentId);
    if (descriptor == null) return null;
    if (!descriptor.launch.firstRunPrompt.matchedBy(screen)) return null;
    final name = descriptor.displayName;
    return '$name is asking whether to trust $directory, and nobody is there '
        'to answer. Open the session once and answer it, then the automation '
        'can run unattended. Karmashala does not trust a folder on your '
        'behalf; $name was left at that question.';
  }

  /// Names a launched agent must not inherit from this process: a parent
  /// agent session's markers, which would make it believe it is nested.
  Set<String> withheldEnvironment(
    String agentId,
    Map<String, String> environment,
  ) => inheritedParentSession(descriptorOf(agentId), environment);
}
