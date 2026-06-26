import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../data/agent_discovery_service.dart';
import '../domain/agent_installation.dart';
import 'agent_providers.dart';

/// Holds the known agent installations and can (re)discover them across every
/// known execution environment.
class AgentInstallationsController extends Notifier<List<AgentInstallation>> {
  @override
  List<AgentInstallation> build() =>
      ref.watch(agentInstallationDaoProvider).getAll();

  /// Probes every known environment for installed agents and persists any not
  /// already recorded (matched by natural identity). Returns the total set of
  /// installations discovered this run.
  Future<List<AgentInstallation>> discoverAll() async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final factory = ref.read(commandRunnerFactoryProvider);
    final dao = ref.read(agentInstallationDaoProvider);
    final ids = ref.read(idGeneratorProvider);
    final clock = ref.read(clockProvider);

    final discovered = <AgentInstallation>[];
    for (final environment in environments) {
      final runner = factory.forEnvironment(environment);
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: environment,
        ids: ids,
        clock: clock,
      ).discover();
      for (final installation in found) {
        discovered.add(installation);
        final existing = dao.getByIdentity(
          installation.agentKind,
          installation.environmentId,
          installation.executable.path,
        );
        if (existing == null) dao.insert(installation);
      }
    }

    state = dao.getAll();
    return discovered;
  }
}

final agentInstallationsControllerProvider =
    NotifierProvider<AgentInstallationsController, List<AgentInstallation>>(
      AgentInstallationsController.new,
    );
