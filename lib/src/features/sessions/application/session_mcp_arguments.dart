import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../mcp/session_mcp.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'session_working_directory.dart';

/// The flags that point one agent at this app's MCP endpoint — the only
/// volatile half of a command line, so they are rebuilt each launch, not kept.
List<String> agentMcpArguments(
  AgentDescriptor? descriptor, {
  String? url,
  String? configPath,
}) {
  final support = descriptor?.launch.mcp;
  if (support == null) return const [];
  if (support.needsConfigFile) {
    return configPath == null || configPath.isEmpty
        ? const []
        : support.argumentsFor(url: url, configPath: configPath);
  }
  return url == null || url.isEmpty
      ? const []
      : support.argumentsFor(url: url, configPath: configPath);
}

/// How a session will reach Karmashala's own tools, or `null`, which is
/// ordinary and never an error: the launch is then what it was before MCP.
SessionMcpAccess? sessionMcpAccessFor(
  Ref ref, {
  required String sessionId,
  required AgentDescriptor? descriptor,
  required ExecutionEnvironment environment,
}) {
  try {
    final mcp = ref.read(sessionMcpProvider);
    final support = descriptor?.launch.mcp;
    if (mcp == null || support == null || !support.isSupported) return null;
    return mcp.accessFor(
      sessionId: sessionId,
      environment: environment,
      withConfigFile: support.needsConfigFile,
    );
  } on Object {
    // Wiring an agent to the tool surface is an enhancement: the one thing this
    // must not do is throw into the caller.
    return null;
  }
}

/// Rebuilds the MCP flags for a pane's [AgentPaneLaunch] against the server
/// running *now*.
typedef AgentPaneMcpArguments = List<String> Function(AgentPaneLaunch launch);

/// What a pane about to be (re)started is told about the MCP endpoint, resolved
/// afresh from the row. `const []` for every "we cannot say", never old flags.
final agentPaneMcpArgumentsProvider = Provider<AgentPaneMcpArguments>(
  (ref) => (launch) {
    try {
      final sessionId = launch.sessionId;
      if (sessionId == null || sessionId.isEmpty) return const [];
      final directory = sessionWorkingDirectory(ref, sessionId);
      if (directory == null) return const [];
      final environment = ref
          .read(executionEnvironmentDaoProvider)
          .getById(directory.environmentId);
      if (environment == null) return const [];
      final descriptor = ref.read(agentRegistryProvider).byId(launch.agentId);
      final access = sessionMcpAccessFor(
        ref,
        sessionId: sessionId,
        descriptor: descriptor,
        environment: environment,
      );
      return agentMcpArguments(
        descriptor,
        url: access?.url,
        configPath: access?.configPath,
      );
    } on Object {
      // A container with no database and no registry — a terminal-only test,
      // and any bootstrap that has not opened one. The pane still starts.
      return const [];
    }
  },
);
