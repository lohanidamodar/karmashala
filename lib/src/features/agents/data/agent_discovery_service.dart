import 'dart:io';

import '../../../core/process/command_runner.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_registry.dart';

/// The command that locates an executable by name in a given environment:
/// `where` on Windows, `command -v` in a POSIX environment.
///
/// The POSIX lookup runs through a **login** shell so the machine's PATH
/// additions — e.g. `~/.local/bin`, where agent CLIs are commonly installed —
/// are present. A bare `which` runs in a non-login shell that cannot see them,
/// so those agents go undetected.
///
/// Which login shell differs by environment, and it matters:
///
/// - WSL and SSH get `bash`, which is what those environments are configured
///   through and what is guaranteed to be installed in a distribution.
/// - The **local** POSIX host gets the *owner's* shell from `$SHELL`, because
///   on macOS that is `zsh` and has been since Catalina. `bash -l` there reads
///   `~/.bash_profile` and never `~/.zprofile`, so on a stock Mac — where PATH
///   is set in the zsh files and often nowhere else — every agent CLI is
///   invisible to a bash login shell while working perfectly in the user's
///   terminal.
///
/// [loginShell] overrides the local host's shell, so the branch is testable
/// without depending on the shell of whoever runs the suite.
CommandRequest locateRequest(
  EnvironmentKind kind,
  String executableName, {
  String? loginShell,
}) {
  if (!isPosixShell(kind)) {
    return CommandRequest(executable: 'where', arguments: [executableName]);
  }
  final shell = kind == EnvironmentKind.localPosix
      ? (loginShell ?? localLoginShell())
      : 'bash';
  return CommandRequest(
    executable: shell,
    arguments: ['-lc', 'command -v $executableName'],
  );
}

/// The owner's login shell on this machine, or `bash` when `$SHELL` says
/// nothing usable.
///
/// Only an absolute path is trusted. `$SHELL` is inherited from whatever
/// launched the app, and a relative or empty value would make the probe spawn
/// something off `PATH` — which is the one thing this function exists to stop
/// depending on.
String localLoginShell() {
  final shell = Platform.environment['SHELL']?.trim();
  if (shell == null || shell.isEmpty || !shell.startsWith('/')) return 'bash';
  return shell;
}

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
  ///
  /// [agentIds] narrows the search to those descriptors. Each probe is a
  /// process — two over WSL, where every one is slow — so a caller that already
  /// knows which agents are worth asking about says so rather than paying for
  /// the whole registry.
  Future<List<DiscoveredAgent>> probeAll({Set<String>? agentIds}) async {
    final wanted = agentIds == null
        ? registry.descriptors
        : [
            for (final d in registry.descriptors)
              if (agentIds.contains(d.id)) d,
          ];
    // The probes are independent subprocesses. Run them concurrently so a
    // slow or missing CLI does not serially delay every other agent check.
    final probed = await Future.wait(wanted.map(_probe));
    return probed.whereType<DiscoveredAgent>().toList();
  }

  /// Discovered agents as persistable installations.
  ///
  /// Every descriptor that was found becomes an installation, keyed by its
  /// `AgentDescriptor.id`. An agent needs no `AgentKind` member to be stored —
  /// only a registry entry.
  Future<List<AgentInstallation>> discover({Set<String>? agentIds}) async {
    final found = await probeAll(agentIds: agentIds);
    return [
      for (final agent in found)
        AgentInstallation(
          id: ids.newId(),
          agentId: agent.descriptor.id,
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
