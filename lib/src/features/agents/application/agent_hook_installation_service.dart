import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../data/agent_hook_installer.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_hook_endpoint.dart';
import 'agent_hook_reachability.dart';
import 'agent_providers.dart';
import 'agent_status_providers.dart';

/// No address this app bound serves this kind of environment at all.
const String _noAddressBound =
    'no callback address this app binds is reachable from this environment';

/// What the last install sweep did, for anything that has to say so out loud.
///
/// A hook that was not installed is not a transient error: for the rest of the
/// run, `awaitingApproval` and `failed` cannot be reported for any session in
/// that environment, because no shipped CLI writes them to a transcript in a
/// form worth trusting. That is a degraded app, and the only trace it used to
/// leave was one `I bootstrap:` line in a file nobody opens — which is how a
/// day went by with nine sessions on disk probes.
class AgentHookInstallationReport {
  const AgentHookInstallationReport(this.results);

  static const AgentHookInstallationReport none = AgentHookInstallationReport(
    <AgentHookInstallation>[],
  );

  final List<AgentHookInstallation> results;

  int get installed => results.where((r) => r.installed).length;

  /// Why each environment got nothing, one entry per environment rather than
  /// one per agent: the reason is a property of the door, and four copies of
  /// it is a wall of text saying one thing.
  Map<String, String> get skippedByEnvironment => {
    for (final result in results)
      if (!result.installed && result.skippedBecause != null)
        result.environmentId: result.skippedBecause!,
  };

  bool get anySkipped => skippedByEnvironment.isNotEmpty;
}

/// Ambient state, written after each sweep by whoever ran it.
class AgentHookInstallationReportController
    extends Notifier<AgentHookInstallationReport> {
  @override
  AgentHookInstallationReport build() => AgentHookInstallationReport.none;

  void set(AgentHookInstallationReport next) => state = next;
}

final agentHookInstallationReportProvider =
    NotifierProvider<
      AgentHookInstallationReportController,
      AgentHookInstallationReport
    >(AgentHookInstallationReportController.new);

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

/// Writes Karmashala's status callbacks into the agents' own hook configs at
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
///   What it rewrites each time is no longer the config, though: since Loop 71
///   the entry names a constant script and the address and the token live in an
///   endpoint file the script reads when a hook fires (see
///   `AgentHookInstaller`). So [retireEndpoints] — not [uninstallAll] — is what
///   runs on the way out, and it deletes exactly the volatile half.
///
///   That closes the hazard this bullet used to describe. A stale *entry* used
///   to survive quitting **and** uninstalling the app, cost a `curl -m 2` on
///   every tool call for ever, and hand its bearer token to whatever bound that
///   port next. Now: the entry that survives is a constant naming a script; the
///   script finds no endpoint file and exits zero without dialling anything;
///   and if an unclean exit leaves the endpoint file behind, the script still
///   sends nothing until an unauthenticated probe comes back `401`, which is
///   what this app answers to a credential-less `GET /agent-hook` and a
///   stranger on that port does not.
/// * **The address depends on where the agent runs, and some agents cannot be
///   reached at all.** `127.0.0.1` inside a WSL2 distribution is that
///   distribution's own loopback, so a loopback hook installed there would fire
///   on every tool call and never arrive. It is the host side of the WSL
///   virtual switch that works, and [AgentHookEndpoint] carries it. **Having
///   bound that address is not evidence that it answers**, and the two came
///   apart on the owner's machine: the switch address reset every byte sent to
///   it from inside the distribution, while the same process served that same
///   distribution on the host's other addresses. So a WSL store is installed
///   only once [AgentHookReachability] has dialled the door from inside it. An
///   SSH host is on another machine and is always skipped. Skipped environments
///   fall back to the state-file and terminal-grid sources, which need no
///   callback.
class AgentHookInstallationService {
  AgentHookInstallationService(this._ref, {AppLogger? logger})
    : _log = logger ?? AppLogger.named('agent-hooks');

  final Ref _ref;
  final AppLogger _log;

  Future<List<AgentHookInstallation>> installAll(AgentHookEndpoint endpoint) =>
      _forEachStore(
        verb: 'install',
        skipUnreachable: true,
        endpoint: endpoint,
        act: (installer, descriptor, home, kind) => installer.install(
          descriptor: descriptor,
          storeHome: home,
          endpoint: endpoint,
          // Never null here: a store whose environment has no row is
          // unreachable by the rule below, and install skips the unreachable.
          environment: kind!,
        ),
      );

  /// Deletes every endpoint file [installAll] wrote, leaving the config entries
  /// and the scripts in place. **This is what runs on the way out.**
  ///
  /// The entry and the script are constants; the address and the token are not,
  /// and they die with this process. Retiring only the endpoint file leaves
  /// nothing behind that names a port, and leaves the entry where it is — which
  /// is the point of making it constant in the first place. A config we do not
  /// rewrite is a config we cannot lose the race for.
  ///
  /// Unreachable environments are swept too, for the same reason
  /// [uninstallAll] sweeps them: a file an earlier build wrote is still ours.
  Future<List<AgentHookInstallation>> retireEndpoints() => _forEachStore(
    verb: 'retire the endpoint for',
    skipUnreachable: false,
    act: (installer, descriptor, home, _) async =>
        installer.retireEndpoint(descriptor: descriptor, storeHome: home),
  );

  /// Removes every hook [installAll] wrote — entries, scripts and endpoint
  /// files alike.
  ///
  /// The complete removal, for a user who wants this app out of their agents'
  /// configuration and for the unreachable-environment sweep in [installAll],
  /// where an entry that cannot deliver has no business staying. The *exit*
  /// path is [retireEndpoints]: see its doc for why taking the entry out twice
  /// a launch was itself the bug.
  ///
  /// Unreachable environments are swept too, unlike [installAll]: they should
  /// hold nothing of ours, and if an older build wrote one — or this launch
  /// wrote one and the next one finds no switch address — this is what removes
  /// it. A config with no entry of ours is read and not written.
  ///
  /// The sweep matches on [agentHookMarker] and never on the URL, which is what
  /// makes it survive an ephemeral port *and* a switch address that moved
  /// between boots.
  Future<List<AgentHookInstallation>> uninstallAll() => _forEachStore(
    verb: 'uninstall',
    skipUnreachable: false,
    act: (installer, descriptor, home, _) =>
        installer.uninstall(descriptor: descriptor, storeHome: home),
  );

  /// The install/uninstall walk: every located store, every hook-capable agent,
  /// one result row each. Written once because the two directions have to visit
  /// exactly the same files — a sweep that missed a store would leave the entry
  /// it was built to remove.
  Future<List<AgentHookInstallation>> _forEachStore({
    required String verb,
    required bool skipUnreachable,
    AgentHookEndpoint? endpoint,
    required Future<bool> Function(
      AgentHookInstaller installer,
      AgentDescriptor descriptor,
      String home,
      EnvironmentKind? kind,
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
      final kind = environment?.kind;
      // An environment we have no row for is treated as unreachable rather than
      // guessed at: the wrong address here is a hook in someone's config that
      // silently never arrives.
      var reachable = kind != null && (endpoint?.reaches(kind) ?? false);
      var unreachableBecause = _noAddressBound;
      // Bound is not the same as reachable. `reaches` says this app bound an
      // address for this kind of environment; only a round trip *from inside*
      // it says an agent there can dial it, and on the owner's machine those
      // two answers disagreed all day. See [AgentHookReachability]. Once per
      // store, outside the descriptor loop: the door is a property of the
      // environment, not of the agent.
      if (reachable && skipUnreachable) {
        reachable = await _ref
            .read(agentHookReachabilityProvider)
            .answersFrom(environment!, endpoint!);
        if (!reachable) {
          unreachableBecause =
              'the callback address ${endpoint.hostFor(kind)} does not '
              'answer from inside this environment';
          _log.warning(
            'Agent hooks for ${store.environmentId} were not installed: '
            '$unreachableBecause. Nothing this app can bind is reachable from '
            'there, so status falls back to disk probes and the hook-only '
            'states (awaiting approval, failed) will not be reported.',
          );
        }
      }
      for (final descriptor in registry.descriptors) {
        if (descriptor.hooks == null) continue;
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        if (skipUnreachable && !reachable) {
          // Not just skipped — *cleaned*. Skipping only decided what not to
          // write, and left whatever was already in the file: an entry an
          // earlier build wrote while the address was still reachable, or one
          // spelling a noisier command than this version writes. That entry
          // keeps firing on every prompt, and the owner watched it print
          // `curl: (52) Empty reply from server` into a live session and fail
          // the hook. A callback we cannot deliver has no business staying in
          // somebody's config, so removing ours is the only honest state here.
          var removed = false;
          try {
            removed = await installer.uninstall(
              descriptor: descriptor,
              storeHome: home,
            );
          } catch (error, stack) {
            _log.warning(
              'Could not remove unreachable ${descriptor.id} hooks in '
              '${store.environmentId}; leaving the config untouched.',
              error,
              stack,
            );
          }
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: false,
              skippedBecause: removed
                  ? '$unreachableBecause; the hook left here by an earlier '
                        'run was removed'
                  : '$unreachableBecause; status falls back to the state file',
            ),
          );
          continue;
        }
        try {
          final applied = await act(installer, descriptor, home, kind);
          if (!applied && endpoint != null) {
            // An install that did not land. [AgentHookInstaller.install] now
            // reads the file back, so this is a fact about disk rather than
            // about our intent — and it has to say so, because the count it
            // feeds ("N installed, M skipped") is the only place anyone would
            // notice. Silence here is what let the owner's app report
            // "1 installed" all day with nothing in any config home.
            _log.warning(
              'Wrote ${descriptor.id} hooks in ${store.environmentId} but the '
              'config does not carry them; status falls back to the state '
              'file. Another process rewriting $home is the usual cause.',
            );
          }
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: applied,
              skippedBecause: applied || endpoint == null
                  ? null
                  : 'the callbacks were written but are not in the config '
                        'file; something else rewrote it',
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
