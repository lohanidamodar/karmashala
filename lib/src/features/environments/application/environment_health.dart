import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import 'environment_providers.dart';
import '../domain/execution_environment.dart';

enum HealthLevel { healthy, warning, failed }

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

final environmentHealthProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(environmentHealthServiceProvider).checkAll(),
);
