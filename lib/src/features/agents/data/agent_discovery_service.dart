import 'dart:io' show Platform;

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

/// A command that succeeds in [kind] iff the environment can run anything at
/// all, or `null` when the question does not arise.
///
/// Only a reconciling scan needs this. "Found nothing" and "could not look" are
/// the same [CommandResult] — a stopped WSL distribution answers `command -v`
/// with a non-zero exit exactly like a distribution with no agents in it — and
/// a re-detect that deleted a running machine's installations because the
/// distro happened to be shut down would be a lie wearing a scan's clothes.
///
/// The **local host** returns `null`, whichever OS it is: it is the machine
/// executing this code, so spawning a process to establish that it exists
/// proves nothing. Only an environment that can be *away* — a WSL distribution
/// that is shut down, an SSH host that is off the network — has a reachability
/// question worth asking.
CommandRequest? reachabilityRequest(EnvironmentKind kind) =>
    isPosixShell(kind) && !isLocalHost(kind)
    ? const CommandRequest(executable: 'bash', arguments: ['-lc', 'exit 0'])
    : null;

/// Expands `%VAR%` placeholders in a Windows path template, or returns `null`
/// if any of them is unset.
///
/// Null rather than a partial expansion: `%USERPROFILE%\.local\bin\claude.exe`
/// with no `USERPROFILE` is not a path, and probing it literally would spawn a
/// process that can only fail.
String? expandWindowsPath(String template, Map<String, String> environment) {
  // Windows environment variable names are case-insensitive; the map is not.
  final byUpperCase = {
    for (final entry in environment.entries)
      entry.key.toUpperCase(): entry.value,
  };
  var missing = false;
  final expanded = template.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
    final value = byUpperCase[match.group(1)!.toUpperCase()];
    if (value == null) missing = true;
    return value ?? '';
  });
  return missing ? null : expanded;
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

/// Everything one sweep of one environment established — including the two
/// facts a bare list of hits cannot express: which agents were asked about and
/// not installed, and whether the environment could be reached at all.
class EnvironmentProbe {
  const EnvironmentProbe({
    required this.found,
    required this.missingAgentIds,
    required this.reachable,
    this.error,
  });

  final List<DiscoveredAgent> found;

  /// Agents that were probed for and are not installed here. Meaningless when
  /// [reachable] is false — nothing was established about them.
  final List<String> missingAgentIds;

  /// Whether the environment answered at all. `false` means the results say
  /// nothing about what is installed, only that we could not look.
  final bool reachable;

  /// Why the environment could not be reached, when it could not.
  final String? error;
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
    Map<String, String>? hostEnvironment,
  }) : hostEnvironment = hostEnvironment ?? Platform.environment;

  final CommandRunner runner;
  final ExecutionEnvironment environment;
  final IdGenerator ids;
  final Clock clock;
  final AgentRegistry registry;

  /// The host process's variables, used only to expand the descriptors'
  /// declared Windows install paths. Injected so tests never depend on the
  /// machine they run on.
  final Map<String, String> hostEnvironment;

  /// Every registry agent found in this environment, descriptor included.
  ///
  /// [agentIds] narrows the search to those descriptors. Each probe is a
  /// process — two over WSL, where every one is slow — so a caller that already
  /// knows which agents are worth asking about says so rather than paying for
  /// the whole registry.
  Future<List<DiscoveredAgent>> probeAll({Set<String>? agentIds}) async {
    // The probes are independent subprocesses. Run them concurrently so a
    // slow or missing CLI does not serially delay every other agent check.
    final probed = await Future.wait(_wanted(agentIds).map(_probe));
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
    var path = await _locateOnPath(descriptor);
    String? version;

    if (path == null) {
      final hit = await _locateAtDeclaredPath(descriptor);
      if (hit == null) return null;
      path = hit.path;
      // Running the file is what proved it exists, so its output is the
      // version we already have; asking again would be a second process for an
      // answer in hand.
      version = hit.version;
    }

    if (version == null && descriptor.discovery.probeVersion) {
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
  Future<String?> _locateOnPath(AgentDescriptor descriptor) async {
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

  /// Tries the descriptor's declared Windows install locations.
  ///
  /// Existence is established by **running** the candidate with the same
  /// `--version` arguments a PATH hit gets: `dart:io` raises for an executable
  /// that is not there, which [CommandRunner] surfaces as [CommandException],
  /// so one process answers "is it installed" and "which version" together.
  /// Doing it this way also keeps discovery inside the [CommandRunner]
  /// abstraction — nothing here touches the filesystem.
  ///
  /// A descriptor with `probeVersion: false` declares that running its binary
  /// to interrogate it is not safe, so it gets no fallback: we have no other
  /// way to ask, and inventing one would mean guessing.
  Future<({String path, String? version})?> _locateAtDeclaredPath(
    AgentDescriptor descriptor,
  ) async {
    if (environment.kind != EnvironmentKind.windowsNative) return null;
    if (!descriptor.discovery.probeVersion) return null;

    for (final template in descriptor.binaries.windowsInstallPaths) {
      final path = expandWindowsPath(template, hostEnvironment);
      if (path == null) continue; // An unset variable is not a path.
      try {
        final result = await runner.run(
          CommandRequest(
            executable: path,
            arguments: descriptor.discovery.versionArguments,
          ),
        );
        // It started, so the file is there — even if it exited non-zero.
        return (
          path: path,
          version: result.ok ? parseAgentVersion(result.stdout) : null,
        );
      } on CommandException {
        continue; // Nothing at this location.
      }
    }
    return null;
  }

  /// Probes this environment and reports what it established, including the
  /// misses and whether the environment answered at all.
  Future<EnvironmentProbe> probeEnvironment({Set<String>? agentIds}) async {
    final wanted = _wanted(agentIds);

    final liveness = reachabilityRequest(environment.kind);
    if (liveness != null) {
      try {
        final result = await runner.run(liveness);
        if (!result.ok) {
          return EnvironmentProbe(
            found: const [],
            missingAgentIds: const [],
            reachable: false,
            error: result.stderr.trim().isEmpty
                ? '${environment.name} did not respond '
                      '(exit ${result.exitCode}).'
                : result.stderr.trim(),
          );
        }
      } on CommandException catch (e) {
        return EnvironmentProbe(
          found: const [],
          missingAgentIds: const [],
          reachable: false,
          error: e.message,
        );
      }
    }

    final probed = await Future.wait(wanted.map(_probe));
    final found = probed.whereType<DiscoveredAgent>().toList();
    final foundIds = {for (final agent in found) agent.descriptor.id};
    return EnvironmentProbe(
      found: found,
      missingAgentIds: [
        for (final descriptor in wanted)
          if (!foundIds.contains(descriptor.id)) descriptor.id,
      ],
      reachable: true,
    );
  }

  List<AgentDescriptor> _wanted(Set<String>? agentIds) => agentIds == null
      ? registry.descriptors
      : [
          for (final d in registry.descriptors)
            if (agentIds.contains(d.id)) d,
        ];
}
