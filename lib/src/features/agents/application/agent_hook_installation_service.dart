import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../domain/agent_hook_endpoint.dart';
import 'agent_providers.dart';
import 'agent_status_providers.dart';

/// One agent config the installer touched, or declined to.
class AgentHookInstallation {
  const AgentHookInstallation({
    required this.agentId,
    required this.environmentId,
    required this.installed,
    this.skippedBecause,
  });

  final String agentId;
  final String environmentId;
  final bool installed;

  /// Why nothing was written, for an environment or agent we deliberately
  /// skipped. `null` when [installed].
  final String? skippedBecause;
}

/// Writes Chitragupta's status callbacks into the agents' own hook configs at
/// startup, and reports exactly what it did.
///
/// [AgentHookInstaller] has existed since Loop 28 with no call site, which made
/// the two most useful status states unreachable in the running app:
/// `awaitingApproval` and `failed` are hook-only, because neither shipped CLI
/// writes them to a transcript in a form worth trusting. Everything downstream
/// of them — the tray's "your agent is blocked" notification most of all — was
/// wired, tested and inert.
///
/// Three properties this has to keep:
///
/// * **The file belongs to the user.** The installer splices only the `hooks`
///   value back in and marks its own entries, so hooks the user configured
///   survive an install, an uninstall and a re-install unchanged.
/// * **The port is ephemeral**, so this runs on every launch rather than once.
///   A hook left over from a previous run points at a port nothing is listening
///   on and costs an immediate connection-refused, bounded by the `curl -m 2`
///   in the command itself.
/// * **WSL cannot reach the endpoint.** Under WSL2's default NAT networking
///   `127.0.0.1` inside a distro is not the Windows host, so a hook installed
///   into a WSL config would fire on every tool call and never arrive. Those
///   environments are skipped explicitly and fall back to the state-file and
///   terminal-grid sources, which need no callback.
class AgentHookInstallationService {
  AgentHookInstallationService(this._ref, {AppLogger? logger})
    : _log = logger ?? AppLogger.named('agent-hooks');

  final Ref _ref;
  final AppLogger _log;

  Future<List<AgentHookInstallation>> installAll(
    AgentHookEndpoint endpoint,
  ) async {
    final results = <AgentHookInstallation>[];
    final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
    if (environments.isEmpty) return results;

    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final byId = {for (final e in environments) e.id: e};
    final installer = _ref.read(agentHookInstallerProvider);
    final registry = _ref.read(agentRegistryProvider);

    for (final store in stores) {
      final environment = byId[store.environmentId];
      final reachable = environment?.kind == EnvironmentKind.windowsNative;
      for (final descriptor in registry.descriptors) {
        if (descriptor.hooks == null) continue;
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        if (!reachable) {
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: false,
              skippedBecause:
                  'the loopback endpoint is not reachable from this '
                  'environment; status falls back to the state file',
            ),
          );
          continue;
        }
        try {
          final installed = await installer.install(
            descriptor: descriptor,
            storeHome: home,
            endpoint: endpoint,
          );
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: installed,
            ),
          );
        } catch (error, stack) {
          // Someone's real config. A file we cannot parse is left exactly as it
          // is, and the app starts anyway — an agent whose status we cannot
          // observe is a much smaller problem than a rewritten settings file.
          _log.warning(
            'Could not install ${descriptor.id} hooks in '
            '${store.environmentId}; leaving the config untouched.',
            error,
            stack,
          );
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: false,
              skippedBecause: '$error',
            ),
          );
        }
      }
    }
    return results;
  }
}

final agentHookInstallationServiceProvider =
    Provider<AgentHookInstallationService>(
      (ref) => AgentHookInstallationService(ref),
    );
