part of '../agent_descriptor.dart';

/// How an agent is driven over the Agent Client Protocol
/// (https://agentclientprotocol.com): JSON-RPC over the process's own stdio,
/// in place of a terminal. Declared on a descriptor; a consumer asks
/// `adapter.acp != null`, never who the agent is.
class AcpLaunchSpec {
  const AcpLaunchSpec({
    this.arguments = const [],
    this.modeNames = const {},
    this.authMethodId,
    this.clientName = 'Karmashala',
    this.npxPackage,
    this.environment = const {},
    this.linuxArguments = const [],
    this.registryId,
    this.apiKeyVariables = const {},
  });

  /// Argv that puts the binary into ACP stdio mode — `['--acp']`,
  /// `['agent', 'stdio']`, or empty for a dedicated adapter binary.
  final List<String> arguments;

  /// Argv added after [arguments] on Linux only — WSL, or a Linux host —
  /// where the registry's Linux build wants something its other builds do
  /// not (`--uid=` for Antigravity). See [argumentsFor].
  final List<String> linuxArguments;

  /// The public ACP registry's id for this agent, when it ships there as a
  /// prebuilt archive Karmashala can install into its managed folder
  /// (`~/karmashala/acp/<registryId>/<version>/`) and find there again.
  final String? registryId;

  /// The mode argv for one machine: [arguments], then [linuxArguments] when
  /// [linux].
  List<String> argumentsFor({required bool linux}) => [
    ...arguments,
    if (linux) ...linuxArguments,
  ];

  /// Whether an agent started in an environment of [kind] runs on Linux: a
  /// WSL distribution always, the local POSIX host when it is Linux
  /// ([hostIsLinux]) rather than macOS. An SSH box is not asked.
  static bool runsOnLinux(EnvironmentKind kind, {required bool hostIsLinux}) =>
      kind == EnvironmentKind.wsl ||
      (kind == EnvironmentKind.localPosix && hostIsLinux);

  /// Candidate agent mode ids per Karmashala rung, in the agent's own
  /// spelling, matched case-insensitively against what `session/new` offers.
  /// A rung with no entry is one the agent has no mode for.
  final Map<PermissionRisk, List<String>> modeNames;

  /// The auth method to use when the agent demands one, or null for the only
  /// one it advertises.
  final String? authMethodId;

  /// Auth method id → the environment variable that method reads its API key
  /// from, as the agent documents it.
  final Map<String, String> apiKeyVariables;

  /// This spec with [methodId] as its [authMethodId].
  AcpLaunchSpec withAuthMethod(String? methodId) => AcpLaunchSpec(
    arguments: arguments,
    modeNames: modeNames,
    authMethodId: methodId,
    clientName: clientName,
    npxPackage: npxPackage,
    environment: environment,
    linuxArguments: linuxArguments,
    registryId: registryId,
    apiKeyVariables: apiKeyVariables,
  );

  /// What `initialize` announces as `clientInfo.name`.
  final String clientName;

  /// The npm package `npx -y <package>` runs when no binary is installed, or
  /// null for an agent that must be installed first.
  final String? npxPackage;

  /// Variables layered over the launched process's environment — what a
  /// person-added agent's row declares. Empty for the shipped agents.
  final Map<String, String> environment;

  /// The first of [risk]'s candidates among [availableModeIds], in the
  /// agent's own spelling, or null when it offers none of them.
  String? modeFor(PermissionRisk risk, Iterable<String> availableModeIds) {
    final offered = {for (final id in availableModeIds) id.toLowerCase(): id};
    for (final candidate in modeNames[risk] ?? const <String>[]) {
      final match = offered[candidate.toLowerCase()];
      if (match != null) return match;
    }
    return null;
  }
}
