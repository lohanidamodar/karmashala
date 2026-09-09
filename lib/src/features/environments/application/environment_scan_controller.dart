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

/// Probes **one** environment for installed agents.
///
/// Deliberately not the same thing as `AgentInstallationsController.discoverAll`:
/// a remote host has to be dialled to be probed, and dialling every saved host
/// because the user wanted to rescan their laptop is not what they asked for.
/// One environment at a time also means one environment's failure — a refused
/// key, a machine that is off — is reported against that environment instead of
/// disappearing into a whole-app scan.
class EnvironmentScanController extends Notifier<Map<String, EnvironmentScan>> {
  @override
  Map<String, EnvironmentScan> build() => const {};

  EnvironmentScan scanOf(String environmentId) =>
      state[environmentId] ?? const EnvironmentScan();

  Future<void> scan(ExecutionEnvironment environment) async {
    _set(environment.id, const EnvironmentScan(busy: true));
    try {
      // Connect first, explicitly. Agent discovery treats an unavailable
      // environment as "nothing installed", which for a remote host would turn
      // a refused connection into an empty list — a failure wearing the costume
      // of a successful, boring result.
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
        // The third and last caller of discovery, so a per-environment scan
        // sees through a Windows junction chain exactly as the other two do.
        // Without this, the one control a user reaches for after "my agent is
        // not showing up" is the one that still cannot find it.
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
