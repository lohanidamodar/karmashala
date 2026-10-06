
import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/probe/probe_mode.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_providers.dart';
import 'agent_status_providers.dart';

/// No address this app bound serves this kind of environment at all.
const String _noAddressBound =
    'no callback address this app binds is reachable from this environment';

/// What the last install sweep did: a hook that did not install means
/// `awaitingApproval` and `failed` go unreported in that environment all run.
class AgentHookInstallationReport {
  const AgentHookInstallationReport(this.results, {this.swept = true});

  /// **Before any sweep has finished** — not a sweep that found nothing. An
  /// empty [results] would leave the panel reading "the hooks are fine".
  static const AgentHookInstallationReport unswept =
      AgentHookInstallationReport(<AgentHookInstallation>[], swept: false);

  /// A finished sweep that touched nothing: a machine with no hook-capable
  /// agent installed in any environment.
  static const AgentHookInstallationReport none = AgentHookInstallationReport(
    <AgentHookInstallation>[],
  );

  final List<AgentHookInstallation> results;

  /// Whether a sweep has reported at all. `false` only for [unswept].
  final bool swept;

  int get installed => results.where((r) => r.installed).length;

  /// How many store homes did not answer inside their budget. See
  /// [AgentHookInstallation.unknown].
  int get unknown => results.where((r) => r.unknown).length;

  /// Why each environment got nothing, one entry per environment — the reason
  /// is a property of the door, so [unknown] rows and absent agents stay out.
  Map<String, String> get skippedByEnvironment => {
    for (final result in results)
      if (!result.installed &&
          !result.unknown &&
          result.agentPresent &&
          result.skippedBecause != null)
        result.environmentId: result.skippedBecause!,
  };

  /// The environments whose store home did not answer in time. Separate because
  /// "we do not know" and "we know it did not happen" are different claims.
  Map<String, String> get unknownByEnvironment => {
    for (final result in results)
      if (result.unknown && result.skippedBecause != null)
        result.environmentId: result.skippedBecause!,
  };

  bool get anySkipped => skippedByEnvironment.isNotEmpty;

  bool get anyUnknown => unknownByEnvironment.isNotEmpty;

}

/// Ambient state, written after each sweep by whoever ran it.
class AgentHookInstallationReportController
    extends Notifier<AgentHookInstallationReport> {
  @override
  AgentHookInstallationReport build() => AgentHookInstallationReport.unswept;

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
    this.unknown = false,
    this.agentPresent = true,
    this.skippedBecause,
    this.spoolDirectory,
    this.wslDistribution,
  });

  final String agentId;
  final String environmentId;
  final bool installed;

  /// An **admission of ignorance**, not a result: the store home did not answer
  /// in time, and a false "not installed" would send someone hunting a bug.
  final bool unknown;

  /// Whether this agent has a store here at all. `false` is the one
  /// `installed: false` that is not a fault, and must not be shown as one.
  final bool agentPresent;

  /// Why nothing was written, for an environment or agent we deliberately
  /// skipped. `null` when [installed].
  final String? skippedBecause;

  /// Where this agent's hooks drop their payloads, or `null` for a socket
  /// transport. The server drains it (slice 5a); reported, not polled here.
  final String? spoolDirectory;

  /// The distribution [spoolDirectory] lives in. `null` outside WSL.
  final String? wslDistribution;
}

/// Writes Karmashala's status callbacks into the agents' own hook configs at
/// startup. A WSL agent gets a spool directory, not an address; SSH is skipped.
class AgentHookInstallationService {
  AgentHookInstallationService(
    this._ref, {
    AppLogger? logger,
    Duration? storeBudget,
  }) : _log = logger ?? AppLogger.named('agent-hooks'),
       _storeBudget = storeBudget ?? defaultStoreBudget;

  /// How long one store home may take before this reports
  /// [AgentHookInstallation.unknown]. Ten seconds: a touch wakes a distro.
  static const Duration defaultStoreBudget = Duration(seconds: 10);

  final Ref _ref;
  final AppLogger _log;
  final Duration _storeBudget;

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

  /// Deletes every endpoint file [installAll] wrote and leaves the constant
  /// entries and scripts alone, in every store. Whether retiring is this
  /// app's to do at all is the caller's rule — `AppLifecycle`'s step 1b skips
  /// it whenever the endpoints name this machine's server, which outlives it.
  Future<List<AgentHookInstallation>> retireEndpoints() => _forEachStore(
    verb: 'retire the endpoint for',
    skipUnreachable: false,
    act: (installer, descriptor, home, _) =>
        installer.retireEndpoint(descriptor: descriptor, storeHome: home),
  );

  /// Removes every hook [installAll] wrote. Matches on [agentHookMarker] and
  /// never on the URL, so it survives an ephemeral port and a moved address.
  Future<List<AgentHookInstallation>> uninstallAll() => _forEachStore(
    verb: 'uninstall',
    skipUnreachable: false,
    act: (installer, descriptor, home, _) =>
        installer.uninstall(descriptor: descriptor, storeHome: home),
  );

  /// The local stores that carry this app's hook entries but whose endpoint
  /// file is gone or no longer spells [endpoint], as "agent in environment".
  /// Local only: reading a WSL store on a timer keeps its distribution awake.
  Future<List<String>> staleLocalEndpoints(AgentHookEndpoint endpoint) async {
    if (_ref.read(probeModeProvider).enabled) return const [];
    final environments = [
      for (final e in _ref.read(environmentsDataProvider).getAll())
        if (isLocalHost(e.kind) && endpoint.reaches(e.kind)) e,
    ];
    if (environments.isEmpty) return const [];
    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final kinds = {for (final e in environments) e.id: e.kind};
    final installer = _ref.read(agentHookInstallerProvider);
    final stale = <String>[];
    for (final store in stores) {
      final kind = kinds[store.environmentId];
      if (kind == null) continue;
      for (final descriptor in _ref.read(agentRegistryProvider).descriptors) {
        final home = store.homesByAgentId[descriptor.id];
        if (descriptor.hooks == null || home == null) continue;
        try {
          // A store this app never installed into has nothing to heal.
          final events = await installer.installedEvents(
            descriptor: descriptor,
            storeHome: home,
            endpoint: endpoint,
            environment: kind,
          );
          if (events.isEmpty) continue;
          if (await installer.endpointIsCurrent(
            descriptor: descriptor,
            storeHome: home,
            endpoint: endpoint,
            environment: kind,
          )) {
            continue;
          }
          stale.add(
            '${descriptor.id} in ${describeEnvironmentId(store.environmentId)}',
          );
        } on Object catch (error, stack) {
          _log.warning(
            'Could not check the ${descriptor.id} hook endpoint in '
            '${describeEnvironmentId(store.environmentId)}.',
            error,
            stack,
          );
        }
      }
    }
    return stale;
  }

  /// The install/uninstall walk: every located store, every hook-capable agent,
  /// one row each. Written once so both directions visit the same files.
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
    // Every direction funnels through here. The stores are the real app's: a
    // probe that installed would point its agents here, one that retired would
    // cut them off, and one that uninstalled would remove their hooks.
    if (_ref.read(probeModeProvider).enabled) {
      _log.info('Probe: not touching agent hooks (would $verb).');
      return const [];
    }
    final environments = _ref.read(environmentsDataProvider).getAll();
    if (environments.isEmpty) return const [];

    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final byId = {for (final e in environments) e.id: e};
    final installer = _ref.read(agentHookInstallerProvider);
    final registry = _ref.read(agentRegistryProvider);

    // Every pair at once, since they are independent: in series one slow share
    // was the whole sweep's cost. `Future.wait` keeps the input order.
    final pending = <Future<AgentHookInstallation>>[];
    for (final store in stores) {
      final environment = byId[store.environmentId];
      final kind = environment?.kind;
      // An environment we have no row for counts as unreachable rather than
      // guessed at: a wrong address is a hook that silently never arrives.
      final reachable = kind != null && (endpoint?.reaches(kind) ?? false);
      for (final descriptor in registry.descriptors) {
        if (descriptor.hooks == null) continue;
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        pending.add(
          _bounded(
            agentId: descriptor.id,
            environmentId: store.environmentId,
            home: home,
            body: () => _oneStore(
              verb: verb,
              skipUnreachable: skipUnreachable,
              endpoint: endpoint,
              act: act,
              installer: installer,
              descriptor: descriptor,
              environmentId: store.environmentId,
              wslDistribution: environment?.wslDistribution,
              kind: kind,
              home: home,
              reachable: reachable,
            ),
          ),
        );
      }
    }
    return Future.wait(pending);
  }

  /// One (agent, store home) pair with its own bound: a slow one becomes a row
  /// saying so. The bound stops the waiting, not the work — writes land whole.
  Future<AgentHookInstallation> _bounded({
    required String agentId,
    required String environmentId,
    required String home,
    required Future<AgentHookInstallation> Function() body,
  }) => body().timeout(
    _storeBudget,
    onTimeout: () {
      final budget = _describeBudget(_storeBudget);
      _log.warning(
        'The store home for $agentId in '
        '${describeEnvironmentId(environmentId)} did not answer within '
        '$budget ($home); whether its status callbacks are in place is '
        'unknown for this run.',
      );
      return AgentHookInstallation(
        agentId: agentId,
        environmentId: environmentId,
        installed: false,
        unknown: true,
        skippedBecause:
            'the store home did not answer within $budget, so whether the '
            'callbacks are in place there is unknown',
      );
    },
  );

  /// The budget in words a person can read. Sub-second in milliseconds, so a
  /// test's tight budget cannot print *"did not answer within 0s"*.
  static String _describeBudget(Duration budget) => budget.inSeconds >= 1
      ? '${budget.inSeconds}s'
      : '${budget.inMilliseconds} ms';

  /// The per-pair body, run concurrently. Never throws: every escape becomes a
  /// row, because the config it touched is somebody's real file.
  Future<AgentHookInstallation> _oneStore({
    required String verb,
    required bool skipUnreachable,
    required AgentHookEndpoint? endpoint,
    required Future<bool> Function(
      AgentHookInstaller installer,
      AgentDescriptor descriptor,
      String home,
      EnvironmentKind? kind,
    )
    act,
    required AgentHookInstaller installer,
    required AgentDescriptor descriptor,
    required String environmentId,
    required String? wslDistribution,
    required EnvironmentKind? kind,
    required String home,
    required bool reachable,
  }) async {
    const unreachableBecause = _noAddressBound;
    if (skipUnreachable && !reachable) {
      // Not just skipped — *cleaned*. An entry from when the address still
      // worked keeps firing: `curl: (52) Empty reply from server`, mid-session.
      var removed = false;
      try {
        removed = await installer.uninstall(
          descriptor: descriptor,
          storeHome: home,
        );
      } catch (error, stack) {
        _log.warning(
          'Could not remove unreachable ${descriptor.id} hooks in '
          '${describeEnvironmentId(environmentId)}; leaving the config untouched.',
          error,
          stack,
        );
      }
      return AgentHookInstallation(
        agentId: descriptor.id,
        environmentId: environmentId,
        installed: false,
        skippedBecause: removed
            ? '$unreachableBecause; the hook left here by an earlier run '
                  'was removed'
            : '$unreachableBecause; status falls back to the state file',
      );
    }
    try {
      final applied = await act(installer, descriptor, home, kind);
      // An agent not installed here has no store and nothing to hook — the one
      // `false` that is not a defect, and must not be reported as one.
      final absent = !await installer.storeIsPresent(home);
      if (!applied && !absent && endpoint != null) {
        // An install that did not land — a fact about disk, since `install`
        // reads back. The "N installed" count is the only place anyone looks.
        _log.warning(
          'Wrote ${descriptor.id} hooks in ${describeEnvironmentId(environmentId)} but the '
          'config does not carry them; status falls back to the state '
          'file. Another process rewriting $home is the usual cause.',
        );
      }
      // Asked of the installer rather than rebuilt here, so the drainer and the
      // uninstall sweep cannot disagree about the path.
      final spool =
          applied &&
              kind != null &&
              endpoint?.transportFor(kind) is AgentHookSpoolTransport
          ? installer.spoolDirectoryFor(descriptor, home)
          : null;
      return AgentHookInstallation(
        agentId: descriptor.id,
        environmentId: environmentId,
        installed: applied,
        // Carried on the row so `skippedByEnvironment` can leave it out: an
        // absent agent is a fact about the agent, not about the environment.
        agentPresent: !absent,
        spoolDirectory: spool?.path,
        wslDistribution: wslDistribution,
        skippedBecause: applied || endpoint == null
            ? null
            : absent
            ? 'the agent is not installed in this environment'
            : 'the callbacks were written but are not in the config file; '
                  'something else rewrote it',
      );
    } catch (error, stack) {
      // Someone's real config. A file we cannot parse is left exactly as it is,
      // and the app starts anyway.
      _log.warning(
        'Could not $verb ${descriptor.id} hooks in '
        '${describeEnvironmentId(environmentId)}; leaving the config untouched.',
        error,
        stack,
      );
      return AgentHookInstallation(
        agentId: descriptor.id,
        environmentId: environmentId,
        installed: false,
        skippedBecause: '$error',
      );
    }
  }
}

final agentHookInstallationServiceProvider =
    Provider<AgentHookInstallationService>(
      (ref) => AgentHookInstallationService(ref),
    );
