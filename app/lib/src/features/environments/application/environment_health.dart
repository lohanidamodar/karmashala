import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import 'environment_providers.dart';

/// How bad a finding is, **ordered by severity** — `index` is the comparison.
/// [unknown] sits above [healthy]: a check that could not run is not a pass.
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
    final environments = ref.read(environmentsDataProvider).getAll();
    return Future.wait(environments.map(check));
  }

  Future<EnvironmentHealth> check(ExecutionEnvironment environment) async {
    final installs = ref
        .read(agentInstallationsDataProvider)
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

// There is no `environmentHealthProvider` any more: it ran these checks on its
// own schedule, so the dialog and Settings could hold two readings of one
// machine. Everything goes through `systemHealthProvider`, stamped with a time.
