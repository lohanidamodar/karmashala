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
  });

  /// Argv that puts the binary into ACP stdio mode — `['--acp']`,
  /// `['agent', 'stdio']`, or empty for a dedicated adapter binary.
  final List<String> arguments;

  /// Candidate agent mode ids per Karmashala rung, in the agent's own
  /// spelling, matched case-insensitively against what `session/new` offers.
  /// A rung with no entry is one the agent has no mode for.
  final Map<PermissionRisk, List<String>> modeNames;

  /// The auth method to use when the agent demands one, or null for the first
  /// it advertises.
  final String? authMethodId;

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
