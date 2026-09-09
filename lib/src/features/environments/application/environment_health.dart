import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import 'environment_providers.dart';
import '../domain/execution_environment.dart';

/// How bad a finding is, **ordered by severity** — `index` is the comparison,
/// so anything added has to go in the right place.
///
/// [unknown] sits above [healthy] on purpose. A check that could not be run is
/// not a passing check, and ranking the two together is how a panel ends up
/// drawing green over an unmeasured machine; it sits below [warning] because
/// not knowing is not yet evidence of a fault.
enum HealthLevel { healthy, unknown, warning, failed }

class EnvironmentHealth {
  const EnvironmentHealth({
    required this.environment,
    required this.level,
    required this.summary,
    required this.installations,
    this.gitVersion,
  });

  final ExecutionEnvironment environment;
  final HealthLevel level;
  final String summary;
  final List<AgentInstallation> installations;
  final String? gitVersion;
}

class EnvironmentHealthService {
  EnvironmentHealthService(this.ref);
  final Ref ref;

  Future<List<EnvironmentHealth>> checkAll() async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    return Future.wait(environments.map(check));
  }

  Future<EnvironmentHealth> check(ExecutionEnvironment environment) async {
    final installs = ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(environment.id);
    try {
      final result = await ref
          .read(commandRunnerFactoryProvider)
          .forEnvironment(environment)
          .run(
            const CommandRequest(executable: 'git', arguments: ['--version']),
          );
      if (!result.ok) {
        return EnvironmentHealth(
          environment: environment,
          level: HealthLevel.failed,
          summary: result.stderr.trim().isEmpty
              ? 'Git exited with code ${result.exitCode}.'
              : result.stderr.trim(),
          installations: installs,
        );
      }
      return EnvironmentHealth(
        environment: environment,
        level: installs.isEmpty ? HealthLevel.warning : HealthLevel.healthy,
        summary: installs.isEmpty
            ? 'Reachable, but no coding agents were discovered.'
            : '${installs.length} coding agent${installs.length == 1 ? '' : 's'} ready.',
        installations: installs,
        gitVersion: result.stdout.trim(),
      );
    } on Object catch (error) {
      return EnvironmentHealth(
        environment: environment,
        level: HealthLevel.failed,
        summary: '$error',
        installations: installs,
      );
    }
  }
}

final environmentHealthServiceProvider = Provider<EnvironmentHealthService>(
  EnvironmentHealthService.new,
);

// There is no `environmentHealthProvider` any more. It ran these checks on its
// own schedule for the health dialog, which meant the dialog and Settings could
// hold two readings of one machine taken at two different times. Everything now
// goes through `systemHealthProvider`, which runs this service once per check
// and stamps the result with when it ran.
