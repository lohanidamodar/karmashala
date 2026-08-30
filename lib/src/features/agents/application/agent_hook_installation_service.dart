import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../data/agent_hook_installer.dart';
import '../domain/agent_descriptor.dart';
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
/// * **The port is ephemeral**, so this runs on every launch rather than once —
///   and [uninstallAll] runs on the way out, so nothing is left pointing at a
///   port this app no longer owns. A stale entry costs an immediate
///   connection-refused, bounded by the `curl -m 2` in the command itself, but
///   it survives quitting *and* uninstalling the app, and hands its bearer
///   token to whatever binds that port next.
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

  Future<List<AgentHookInstallation>> installAll(AgentHookEndpoint endpoint) =>
      _forEachStore(
        verb: 'install',
        skipUnreachable: true,
        act: (installer, descriptor, home) => installer.install(
          descriptor: descriptor,
          storeHome: home,
          endpoint: endpoint,
        ),
      );

  /// Removes every hook [installAll] wrote, on the way out.
  ///
  /// The command names an **ephemeral** port and carries a bearer token, so an
  /// entry left behind outlives the app that could answer it: every tool call
  /// the user makes after quitting runs a `curl` at a port nothing owns, and
  /// the entry survives uninstalling Chitragupta entirely. Bounded and
  /// loopback-only, so this is hygiene rather than a hole — but it is hygiene
  /// in somebody else's config file, which is the kind worth keeping.
  ///
  /// Unreachable environments are swept too, unlike [installAll]: they should
  /// hold nothing of ours, and if an older build wrote one this is what removes
  /// it. A config with no entry of ours is read and not written.
  Future<List<AgentHookInstallation>> uninstallAll() => _forEachStore(
    verb: 'uninstall',
    skipUnreachable: false,
    act: (installer, descriptor, home) =>
        installer.uninstall(descriptor: descriptor, storeHome: home),
  );

  /// The install/uninstall walk: every located store, every hook-capable agent,
  /// one result row each. Written once because the two directions have to visit
  /// exactly the same files — a sweep that missed a store would leave the entry
  /// it was built to remove.
  Future<List<AgentHookInstallation>> _forEachStore({
    required String verb,
    required bool skipUnreachable,
    required Future<bool> Function(
      AgentHookInstaller installer,
      AgentDescriptor descriptor,
      String home,
    )
    act,
  }) async {
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
        if (skipUnreachable && !reachable) {
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
          final applied = await act(installer, descriptor, home);
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: applied,
            ),
          );
        } catch (error, stack) {
          // Someone's real config. A file we cannot parse is left exactly as it
          // is, and the app starts anyway — an agent whose status we cannot
          // observe is a much smaller problem than a rewritten settings file.
          _log.warning(
            'Could not $verb ${descriptor.id} hooks in '
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
