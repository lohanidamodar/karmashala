import '../../environments/domain/environment_kind.dart';
import '../../settings/domain/permission_mode.dart';
import 'agent_kind.dart';
import 'agent_status.dart';

/// How an agent CLI expresses "continue this session".
enum AgentResumeStyle {
  /// A flag before the prompt, e.g. `--resume <id>`.
  flag,

  /// A subcommand, e.g. `codex resume <id>`.
  subcommand,

  /// The agent cannot resume from the command line.
  unsupported,
}

/// One agent's resume convention.
class AgentResume {
  const AgentResume.flag(this.token) : style = AgentResumeStyle.flag;
  const AgentResume.subcommand(this.token)
    : style = AgentResumeStyle.subcommand;
  const AgentResume.unsupported()
    : style = AgentResumeStyle.unsupported,
      token = '';

  final AgentResumeStyle style;
  final String token;

  List<String> argumentsFor(String sessionId) =>
      style == AgentResumeStyle.unsupported ? const [] : [token, sessionId];
}

/// Executable base names to probe, per execution-environment kind. Each list is
/// tried in order and the first hit wins.
class AgentBinaries {
  const AgentBinaries({required this.windows, required this.posix});

  final List<String> windows;
  final List<String> posix;

  List<String> forKind(EnvironmentKind kind) => switch (kind) {
    EnvironmentKind.windowsNative => windows,
    EnvironmentKind.wsl => posix,
  };
}

/// How to confirm a located executable and read its version.
class AgentDiscoveryRules {
  const AgentDiscoveryRules({
    this.probeVersion = true,
    this.versionArguments = const ['--version'],
  });

  final bool probeVersion;
  final List<String> versionArguments;
}

/// The command-line vocabulary of one agent.
///
/// [resume] is the headless/protocol convention the adapters use;
/// [interactiveResume] is the one a TTY launch uses. They differ for Codex
/// (`codex --resume <id>` in app-server mode vs `codex resume <id>` in a
/// terminal), which is why both are recorded.
class AgentLaunchSpec {
  const AgentLaunchSpec({
    this.baseArguments = const [],
    this.permissionArguments = const {},
    this.resume = const AgentResume.unsupported(),
    this.interactiveResume = const AgentResume.unsupported(),
  });

  final List<String> baseArguments;
  final Map<PermissionMode, List<String>> permissionArguments;
  final AgentResume resume;
  final AgentResume interactiveResume;

  List<String> permissionArgumentsFor(PermissionMode mode) =>
      permissionArguments[mode] ?? const [];
}

/// The on-disk layout of an agent's session store.
enum AgentStoreFormat {
  /// `<home>/projects/<dir>/<id>.jsonl`, read by `ClaudeStoreReader`.
  claudeJsonl,

  /// `<home>/sessions/**/rollout-*.jsonl`, read by `CodexStoreReader`.
  codexRollout,

  /// A store we cannot read yet.
  none,
}

/// Where an agent keeps its per-user config and sessions.
class AgentStoreSpec {
  const AgentStoreSpec({required this.homeDirectoryName, required this.format});

  /// Directory name under the environment's home, e.g. `.claude`.
  final String homeDirectoryName;

  final AgentStoreFormat format;
}

/// The best status source an agent supports. The status service falls back down
/// the sources it actually has, so this is a preference, not an exclusive
/// choice. [terminalGrid] is declarable but unimplemented — it needs PTY-hosted
/// sessions — and resolves to `unknown` today.
enum AgentStatusStrategy { hooks, stateFile, terminalGrid, none }

/// Everything Chitragupta needs to find, launch and observe one agent CLI.
///
/// This is data, not code: adding an agent means adding a descriptor. [id] is
/// the agent's identity everywhere — discovery, persistence, settings, sessions
/// and the MCP control server all key on it.
///
/// [kind] is non-null only for the agents that additionally have a hand-written
/// protocol adapter, and is read only when choosing that adapter. A descriptor
/// without one is a complete, usable agent.
class AgentDescriptor {
  const AgentDescriptor({
    required this.id,
    required this.displayName,
    this.kind,
    required this.binaries,
    this.discovery = const AgentDiscoveryRules(),
    this.launch = const AgentLaunchSpec(),
    this.store,
    this.statusStrategy = AgentStatusStrategy.none,
    this.hooks,
    this.stateFile,
  });

  final String id;
  final String displayName;
  final AgentKind? kind;
  final AgentBinaries binaries;
  final AgentDiscoveryRules discovery;
  final AgentLaunchSpec launch;
  final AgentStoreSpec? store;
  final AgentStatusStrategy statusStrategy;
  final AgentHookSpec? hooks;
  final AgentStateFileRules? stateFile;

  @override
  String toString() => 'AgentDescriptor($id)';
}
