import '../../../core/process/command_runner.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_kind.dart';

/// The executable base name probed for each agent kind.
String agentExecutableName(AgentKind kind) => switch (kind) {
  AgentKind.claudeCode => 'claude',
  AgentKind.codex => 'codex',
  AgentKind.antigravity => 'antigravity',
};

/// The command that locates an executable by name in a given environment:
/// `where` on Windows, `which` inside WSL.
CommandRequest locateRequest(EnvironmentKind kind, String executableName) =>
    switch (kind) {
      EnvironmentKind.windowsNative => CommandRequest(
        executable: 'where',
        arguments: [executableName],
      ),
      EnvironmentKind.wsl => CommandRequest(
        executable: 'which',
        arguments: [executableName],
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

/// Detects which agent CLIs are installed in a single execution environment.
///
/// Probing runs entirely through the supplied [runner] (constraint 6): it
/// locates each agent's executable, then asks it for its version. Each result is
/// an independent `(agent, environment)` [AgentInstallation].
class AgentDiscoveryService {
  AgentDiscoveryService({
    required this.runner,
    required this.environment,
    required this.ids,
    required this.clock,
  });

  final CommandRunner runner;
  final ExecutionEnvironment environment;
  final IdGenerator ids;
  final Clock clock;

  Future<List<AgentInstallation>> discover() async {
    final installations = <AgentInstallation>[];
    for (final kind in AgentKind.values) {
      final installation = await _probe(kind);
      if (installation != null) installations.add(installation);
    }
    return installations;
  }

  Future<AgentInstallation?> _probe(AgentKind kind) async {
    final exeName = agentExecutableName(kind);
    final CommandResult located;
    try {
      located = await runner.run(locateRequest(environment.kind, exeName));
    } on CommandException {
      return null; // Environment unavailable — treat as "not installed".
    }
    if (!located.ok) return null;

    final path = firstNonEmptyLine(located.stdout);
    if (path == null) return null;

    String? version;
    try {
      final versionResult = await runner.run(
        CommandRequest(executable: path, arguments: const ['--version']),
      );
      if (versionResult.ok) version = parseAgentVersion(versionResult.stdout);
    } on CommandException {
      // Located but couldn't run --version; record it without a version.
    }

    return AgentInstallation(
      id: ids.newId(),
      agentKind: kind,
      executable: EnvironmentPath(environmentId: environment.id, path: path),
      version: version,
      createdAt: clock.nowUtc(),
    );
  }
}
