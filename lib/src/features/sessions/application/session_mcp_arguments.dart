import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../mcp/session_mcp.dart';
import '../../terminal/domain/agent_pane_launch.dart';
import 'session_working_directory.dart';

/// The flags that point one agent at this app's MCP endpoint, or nothing when
/// there is nothing truthful to say.
///
/// **The volatile half of an agent's command line, and the only volatile
/// half**: the config file is rewritten on the way in, the control server binds
/// whatever port it can get, and the URL's last segment is a credential minted
/// for this process, so these are built at each launch and never stored. A
/// config-file agent is gated on the **file**, not on a URL a WSL session
/// deliberately does not have; an inline-URL agent is gated on the URL.
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

/// How a session will reach Karmashala's own tools, or `null` when it will not.
/// `null` is the ordinary answer and never an error — no control server, no
/// verified convention, an SSH or WSL host with no address to dial, a config
/// directory that could not be locked down. The launch is then byte-identical
/// to the one that happened before any of this existed.
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

/// What a pane about to be (re)started is told about the MCP endpoint. A
/// provider so the terminal layer — which restarts panes and deliberately knows
/// nothing about sessions — has one seam to read.
///
/// Everything is resolved afresh from the session row rather than the stored
/// launch: the row says which environment the agent runs in, and the
/// environment decides whether any address is reachable from there (a WSL2
/// distro refuses the loopback URL a Windows pane gets). Answers `const []` for
/// every "we cannot say" — never the flags of a previous run.
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
