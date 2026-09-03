import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/execution_environment.dart';
import '../../mcp/session_mcp.dart';
import '../../terminal/domain/agent_pane_launch.dart';
import 'session_working_directory.dart';

/// The flags that point one agent at this app's MCP endpoint, or nothing when
/// there is nothing truthful to say.
///
/// **The volatile half of an agent's command line, and the only volatile half.**
/// Every value inside these flags belongs to one run of the app: the config
/// file is deleted and rewritten by `SessionMcpConfigs.prepare` on the way in,
/// the control server binds whatever port it can get, and the URL's last path
/// segment is a credential minted for this process. So they are built at each
/// launch and never stored — see [AgentPaneLaunch.mcpArguments].
/// A config-file agent is pointed at a **file**, and the file is what says how
/// to reach the app — a URL for an agent that shares this loopback, a `command`
/// spawning the stdio bridge for one inside a WSL distribution, which has no
/// address of ours to dial. So the flag is gated on the file, not on a URL that
/// such a session deliberately does not have. An inline-URL agent has nothing
/// but the URL and is still gated on it.
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
///
/// `null` is the ordinary answer and never an error. The control server is not
/// up; the agent has no verified convention; the session runs over SSH, or in
/// WSL on a host with no switch to dial; the config directory could not be
/// locked down. In every case the launch is byte-identical to the one that
/// happened before any of this existed — which is the property that matters
/// most, because a session that opens without its tools is a smaller loss than
/// a session that does not open.
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
    // Wiring an agent to the tool surface is an enhancement. Nothing about it
    // is worth failing a launch over, so the one thing this must not do is
    // throw into the caller.
    return null;
  }
}

/// Rebuilds the MCP flags for a pane's [AgentPaneLaunch] against the server
/// running *now*.
typedef AgentPaneMcpArguments = List<String> Function(AgentPaneLaunch launch);

/// What a pane about to be (re)started is told about the MCP endpoint.
///
/// A provider so the terminal layer — which restarts panes and deliberately
/// knows nothing about sessions — has one seam to read, and so a test can stand
/// one restart's endpoint against another's.
///
/// It resolves everything afresh from the session row rather than from the
/// stored launch: the row is what says which environment the agent runs in, and
/// the environment is what decides whether there is any address reachable from
/// there at all (a WSL2 distro refuses the loopback URL a Windows pane gets).
///
/// Answers `const []` for every "we cannot say": no session behind the pane, no
/// row, no environment, no server. That is the same fail-soft
/// [sessionMcpAccessFor] makes, and it is what a pane restarted while the
/// control server is down must get — never the flags of a previous run.
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
