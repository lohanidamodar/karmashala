import '../../../core/process/command_runner.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_kind.dart';
import '../domain/agent_registry.dart';

/// The executable base name probed for each agent kind, from the registry.
String agentExecutableName(AgentKind kind) =>
    AgentRegistry.builtIn.forKind(kind)!.binaries.windows.first;

/// The command that locates an executable by name in a given environment:
/// `where` on Windows, `command -v` inside WSL.
///
/// The WSL lookup runs through a login shell (`bash -lc`) so the distro's PATH
/// additions — e.g. `~/.local/bin` sourced from `~/.profile`, where agent CLIs
/// are commonly installed — are present. A bare `which` runs in a non-login
/// shell that can't see them, so WSL-installed agents go undetected.
CommandRequest locateRequest(EnvironmentKind kind, String executableName) =>
    switch (kind) {
      EnvironmentKind.windowsNative => CommandRequest(
        executable: 'where',
        arguments: [executableName],
      ),
      EnvironmentKind.wsl => CommandRequest(
        executable: 'bash',
        arguments: ['-lc', 'command -v $executableName'],
      ),
    };

/// First non-blank, trimmed line of [text], or `null` if there is none.
String? firstNonEmptyLine(String text) {
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// Extracts a version from `--version` output: a semantic version if present,
/// otherwise the first non-empty line, otherwise `null`.
String? parseAgentVersion(String output) {
  final match = RegExp(
    r'\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.]+)?',
  ).firstMatch(output);
  if (match != null) return match.group(0);
  return firstNonEmptyLine(output);
}

/// One agent found in one environment, still described by its registry entry.
class DiscoveredAgent {
  const DiscoveredAgent({
    required this.descriptor,
    required this.executable,
    this.version,
  });

  final AgentDescriptor descriptor;
  final EnvironmentPath executable;
  final String? version;
}

/// Detects which agent CLIs are installed in a single execution environment.
///
/// The agents probed and the names probed for come from the [registry], so
/// supporting another agent is a descriptor, not a code change. Probing runs
/// entirely through the supplied [runner] (constraint 6): it locates each
/// agent's executable, then asks it for its version. Each result is an
/// independent `(agent, environment)` installation.
class AgentDiscoveryService {
  AgentDiscoveryService({
    required this.runner,
    required this.environment,
    required this.ids,
    required this.clock,
    this.registry = AgentRegistry.builtIn,
  });

  final CommandRunner runner;
  final ExecutionEnvironment environment;
  final IdGenerator ids;
  final Clock clock;
  final AgentRegistry registry;

  /// Every registry agent found in this environment, descriptor included.
  Future<List<DiscoveredAgent>> probeAll() async {
    // The probes are independent subprocesses. Run them concurrently so a
    // slow or missing CLI does not serially delay every other agent check.
    final probed = await Future.wait(registry.descriptors.map(_probe));
    return probed.whereType<DiscoveredAgent>().toList();
  }

  /// Discovered agents as persistable installations.
  ///
  /// Descriptors without an [AgentKind] are dropped: `AgentInstallation` is
  /// still keyed by that enum, so a registry-only agent can be discovered and
  /// status-detected but not yet stored. Widening the persisted key is the
  /// follow-up recorded in the loop-28 design doc.
  Future<List<AgentInstallation>> discover() async {
    final found = await probeAll();
    return [
      for (final agent in found)
        if (agent.descriptor.kind != null)
          AgentInstallation(
            id: ids.newId(),
            agentKind: agent.descriptor.kind!,
            executable: agent.executable,
            version: agent.version,
            createdAt: clock.nowUtc(),
          ),
    ];
  }

  Future<DiscoveredAgent?> _probe(AgentDescriptor descriptor) async {
    final path = await _locate(descriptor);
    if (path == null) return null;

    String? version;
    if (descriptor.discovery.probeVersion) {
      try {
        final versionResult = await runner.run(
          CommandRequest(
            executable: path,
            arguments: descriptor.discovery.versionArguments,
          ),
        );
        if (versionResult.ok) version = parseAgentVersion(versionResult.stdout);
      } on CommandException {
        // Located but couldn't run --version; record it without a version.
      }
    }

    return DiscoveredAgent(
      descriptor: descriptor,
      executable: EnvironmentPath(environmentId: environment.id, path: path),
      version: version,
    );
  }

  /// Tries each declared binary name in order and returns the first hit.
  Future<String?> _locate(AgentDescriptor descriptor) async {
    for (final name in descriptor.binaries.forKind(environment.kind)) {
      final CommandResult located;
      try {
        located = await runner.run(locateRequest(environment.kind, name));
      } on CommandException {
        return null; // Environment unavailable — treat as "not installed".
      }
      if (!located.ok) continue;
      final path = firstNonEmptyLine(located.stdout);
      if (path != null) return path;
    }
    return null;
  }
}
