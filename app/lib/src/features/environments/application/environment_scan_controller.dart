import 'package:riverpod/riverpod.dart';

import '../../../core/util/agent_cli_bridge.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import '../../ssh/application/ssh_failure.dart';
import '../../ssh/application/ssh_providers.dart';
import 'package:agent_cli/process.dart';

/// What the last agent scan of one environment did.
class EnvironmentScan {
  const EnvironmentScan({this.busy = false, this.error, this.found});

  final bool busy;

  /// Why the scan could not be completed — a refused host key, an unreachable
  /// machine. Distinct from "found nothing", which is a successful scan.
  final String? error;

  /// How many agents the last successful scan found, or null if it has not run.
  final int? found;
}

/// Probes **one** environment for installed agents — not `discoverAll`: a
/// remote host must be dialled, and one failure belongs to one environment.
class EnvironmentScanController extends Notifier<Map<String, EnvironmentScan>> {
  @override
  Map<String, EnvironmentScan> build() => const {};

  EnvironmentScan scanOf(String environmentId) =>
      state[environmentId] ?? const EnvironmentScan();

  Future<void> scan(ExecutionEnvironment environment) async {
    _set(environment.id, const EnvironmentScan(busy: true));
    try {
      // Connect first, explicitly. Discovery treats an unavailable environment as
      // "nothing installed", which for a remote host hides a refusal as an empty list.
      if (environment.kind == EnvironmentKind.ssh) {
        await ref
            .read(sshConnectionPoolProvider)
            .forEnvironment(environment)
            .client();
      }

      final found = await AgentDiscoveryService(
        runner: ref
            .read(commandRunnerFactoryProvider)
            .forEnvironment(environment),
        environment: environment,
        ids: ref.read(agentCliIdsProvider),
        clock: ref.read(agentCliClockProvider),
        registry: ref.read(agentRegistryProvider),
        // The third and last caller of discovery, so a per-environment scan sees
        // through a Windows junction chain exactly as the other two do.
        pathProbe: ref.read(agentCliPathProbeProvider),
        hostEnvironment: ref.read(hostEnvironmentProvider),
      ).discover();

      final dao = ref.read(agentInstallationDaoProvider);
      for (final installation in found) {
        final existing = dao.getByIdentity(
          installation.agentId,
          installation.environmentId,
          installation.executable.path,
        );
        if (existing == null) dao.insert(installation);
      }
      ref.invalidate(agentInstallationsControllerProvider);
      _set(environment.id, EnvironmentScan(found: found.length));
    } on Object catch (e) {
      _set(environment.id, EnvironmentScan(error: describeSshFailure(e)));
    }
  }

  void _set(String environmentId, EnvironmentScan scan) =>
      state = {...state, environmentId: scan};
}

final environmentScanControllerProvider =
    NotifierProvider<EnvironmentScanController, Map<String, EnvironmentScan>>(
      EnvironmentScanController.new,
    );
