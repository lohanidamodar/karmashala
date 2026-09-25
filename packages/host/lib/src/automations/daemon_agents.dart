import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/launch.dart';

/// **The one file in the daemon that reads `agent_cli`** — an agent's adapter
/// and its descriptor. It asks what an agent declares and never which agent it
/// is: no branch on an agent id belongs here or anywhere else in the host.
class DaemonAgents {
  const DaemonAgents([this._registry = AgentRegistry.builtIn]);

  final AgentRegistry _registry;

  /// Everything agent-specific the daemon may ask, behind one boundary.
  AgentAdapter? adapterOf(String agentId) => _registry.adapterFor(agentId);

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

  /// The command line for a new session [sessionId] of [agentId], told
  /// [prompt], pointed at Karmashala's tools by [mcpUrl] or [mcpConfigPath].
  List<String> newSessionArguments({
    required String agentId,
    required String sessionId,
    required String? permissionMode,
    required String prompt,
    String? mcpUrl,
    String? mcpConfigPath,
  }) {
    final descriptor = descriptorOf(agentId);
    final assignsOwnId =
        descriptor?.launch.sessionIdAssignment.isSupported ?? false;
    return agentPaneArguments(
      descriptor,
      permissionOf(agentId, permissionMode),
      sessionId: assignsOwnId ? sessionId : null,
      prompt: prompt,
      mcpUrl: mcpUrl,
      mcpConfigPath: mcpConfigPath,
    );
  }

  /// Whether a new session of [agentId] is started under the id Karmashala
  /// gives it, so the row can name its conversation from the start.
  bool assignsOwnSessionId(String agentId) =>
      descriptorOf(agentId)?.launch.sessionIdAssignment.isSupported ?? false;

  /// The view a new session of [agentId] opens in: chat where its store is
  /// one Karmashala reads, else the terminal.
  SessionView defaultView(String agentId) => defaultViewFor(adapterOf(agentId));

  /// Names a launched agent must not inherit from this process: a parent
  /// agent session's markers, which would make it believe it is nested.
  Set<String> withheldEnvironment(
    String agentId,
    Map<String, String> environment,
  ) => inheritedParentSession(descriptorOf(agentId), environment);
}
