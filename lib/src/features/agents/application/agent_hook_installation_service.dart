import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../data/agent_hook_installer.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_hook_endpoint.dart';
import '../domain/agent_hook_transport.dart';
import 'agent_hook_spool_drainer.dart';
import 'agent_providers.dart';
import 'agent_status_providers.dart';
import '../../environments/domain/environment_label.dart';

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

  /// Every spool directory this sweep installed — one per **agent**, because
  /// each agent keeps its payloads in its own store home.
  ///
  /// This is how `AgentHookSpoolDrainer` learns what to poll without
  /// re-deriving a generated path, which is the mistake that leaves files
  /// behind on uninstall.
  List<AgentHookSpoolSource> get spoolSources => [
    for (final result in results)
      if (result.installed && result.spoolDirectory != null)
        AgentHookSpoolSource(
          environmentId: result.environmentId,
          directory: Directory(result.spoolDirectory!),
          wslDistribution: result.wslDistribution,
        ),
  ];
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
    this.spoolDirectory,
    this.wslDistribution,
  });

  final String agentId;
  final String environmentId;
  final bool installed;

  /// Why nothing was written, for an environment or agent we deliberately
  /// skipped. `null` when [installed].
  final String? skippedBecause;

  /// Where this agent's hooks drop their payloads, for an environment that
  /// reports by file rather than by socket — `null` for every other one.
  ///
  /// Carried out of the sweep rather than recomputed by the drainer: the
  /// installer owns the names of the files it generates, and a second spelling
  /// of one of them is how an uninstall comes to leave something behind.
  final String? spoolDirectory;

  /// The distribution [spoolDirectory] lives in, so the drainer can tell
  /// whether it is worth listing. `null` outside WSL.
  final String? wslDistribution;
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
/// * **How an agent reports depends on where it runs, and some agents cannot
///   report at all.** `127.0.0.1` inside a WSL2 distribution is that
///   distribution's own loopback, and the one address of ours it can name — the
///   host side of the WSL virtual switch — resets every byte sent to it on the
///   owner's machine, for a bare PowerShell listener as readily as for this
///   app. So a WSL agent is not given an address: it is given a spool
///   directory in its own store home, which this app reads over
///   `\\wsl.localhost` and drains with [AgentHookSpoolDrainer]. See
///   [AgentHookEndpoint.transportFor]. An SSH host is on another machine, has
///   no shared filesystem either, and is still always skipped; skipped
///   environments fall back to the state-file and terminal-grid sources, which
///   need no callback.
///
///   The `curl`-from-inside-the-distribution probe that used to gate a WSL
///   install went with the address it was probing. It existed because a bound
///   socket is not a reachable door, and it was right; what replaced it is
///   stronger rather than weaker, because `AgentHookInstaller` reads back every
///   file it writes into that store home and the store home *is* the transport.
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
      // Whether this app has any way at all for an agent there to report.
      // Once per store, outside the descriptor loop: the answer is a property
      // of the environment, not of the agent.
      //
      // This used to be two questions — *did we bind an address for this kind*
      // and then *does that address answer from inside it*, one `curl` per WSL
      // distribution per launch — because a bound socket is not a reachable
      // door and on the owner's machine those two answers disagreed all day.
      // It is one question again because the second one is gone rather than
      // dropped: the only environment whose door had to be dialled now reports
      // by writing a file into a store home the installer reads back byte for
      // byte, which is a stronger check than a status line.
      final reachable = kind != null && (endpoint?.reaches(kind) ?? false);
      const unreachableBecause = _noAddressBound;
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
              '${describeEnvironmentId(store.environmentId)}; leaving the config untouched.',
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
          // An agent that is not installed in this environment has no store
          // and nothing to hook. That is the one `false` which is not a
          // defect, and it must not be reported as one: a Mac with the
          // Antigravity IDE but not its CLI logged "wrote the hooks but the
          // config does not carry them" on every launch, which reads as a
          // config being rewritten under us.
          final absent = !installer.storeIsPresent(home);
          if (!applied && !absent && endpoint != null) {
            // An install that did not land. [AgentHookInstaller.install] now
            // reads the file back, so this is a fact about disk rather than
            // about our intent — and it has to say so, because the count it
            // feeds ("N installed, M skipped") is the only place anyone would
            // notice. Silence here is what let the owner's app report
            // "1 installed" all day with nothing in any config home.
            _log.warning(
              'Wrote ${descriptor.id} hooks in ${describeEnvironmentId(store.environmentId)} but the '
              'config does not carry them; status falls back to the state '
              'file. Another process rewriting $home is the usual cause.',
            );
          }
          // Where this agent's payloads will land, for a transport that
          // reports by file. Asked of the installer rather than rebuilt here,
          // so the drainer and the uninstall sweep can never disagree about
          // the path.
          final spool =
              applied &&
                  kind != null &&
                  endpoint?.transportFor(kind) is AgentHookSpoolTransport
              ? installer.spoolDirectoryFor(descriptor, home)
              : null;
          results.add(
            AgentHookInstallation(
              agentId: descriptor.id,
              environmentId: store.environmentId,
              installed: applied,
              spoolDirectory: spool?.path,
              wslDistribution: environment?.wslDistribution,
              skippedBecause: applied || endpoint == null
                  ? null
                  : absent
                  ? 'the agent is not installed in this environment'
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
            '${describeEnvironmentId(store.environmentId)}; leaving the config untouched.',
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
