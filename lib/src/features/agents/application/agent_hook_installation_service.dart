import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../data/agent_hook_installer.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_hook_spool_drainer.dart';
import 'agent_providers.dart';
import 'agent_status_providers.dart';

/// No address this app bound serves this kind of environment at all.
const String _noAddressBound =
    'no callback address this app binds is reachable from this environment';

/// What the last install sweep did, for anything that has to say so out loud.
///
/// A hook that was not installed is not a transient error: for the rest of the
/// run, `awaitingApproval` and `failed` cannot be reported for any session in
/// that environment. That is a degraded app, and the only trace it used to leave
/// was one `I bootstrap:` line in a file nobody opens.
class AgentHookInstallationReport {
  const AgentHookInstallationReport(this.results, {this.swept = true});

  /// **Before any sweep has finished**, which is not the same thing as a sweep
  /// that found nothing. The sweep runs after the first frame, so an empty
  /// [results] would leave the Tools panel silent for that window — which reads
  /// as *"the hooks are fine"*.
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

  /// Why each environment got nothing, one entry per environment rather than one
  /// per agent: the reason is a property of the door.
  ///
  /// Two kinds of row are deliberately **not** in here, because both read as the
  /// environment's fault when they were folded in — an [unknown] row is a
  /// reading we do not have rather than a decision (see [unknownByEnvironment]),
  /// and an agent that is simply not installed is a fact about that agent.
  Map<String, String> get skippedByEnvironment => {
    for (final result in results)
      if (!result.installed &&
          !result.unknown &&
          result.agentPresent &&
          result.skippedBecause != null)
        result.environmentId: result.skippedBecause!,
  };

  /// The environments whose store home did not answer inside its budget, and
  /// what that means for them. Separate from [skippedByEnvironment] because
  /// "we do not know" and "we know it did not happen" are different claims.
  Map<String, String> get unknownByEnvironment => {
    for (final result in results)
      if (result.unknown && result.skippedBecause != null)
        result.environmentId: result.skippedBecause!,
  };

  bool get anySkipped => skippedByEnvironment.isNotEmpty;

  bool get anyUnknown => unknownByEnvironment.isNotEmpty;

  /// Every spool directory this sweep installed — one per **agent**, because
  /// each keeps its payloads in its own store home. How
  /// `AgentHookSpoolDrainer` learns what to poll without re-deriving a
  /// generated path.
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

  /// Whether this row is an **admission of ignorance** rather than a result: the
  /// store home did not answer inside
  /// [AgentHookInstallationService.defaultStoreBudget], so what is on disk there
  /// is unknown.
  ///
  /// Deliberately not `installed: false` with an ordinary reason: a false *"not
  /// installed"* sends someone looking for a config bug that may not be there.
  /// The work is not cancelled either — a Dart future cannot be — so the files
  /// may land a moment later, and the next launch's sweep is idempotent.
  final bool unknown;

  /// Whether this agent has a store here at all.
  ///
  /// `false` is the one `installed: false` that is **not** a degraded
  /// environment: there was no agent to hook. It still carries a
  /// [skippedBecause], but nothing may present it as a fault — a Mac with two
  /// working agents and no Antigravity CLI was told, in red, that it had no
  /// status callbacks at all.
  final bool agentPresent;

  /// Why nothing was written, for an environment or agent we deliberately
  /// skipped. `null` when [installed].
  final String? skippedBecause;

  /// Where this agent's hooks drop their payloads, for an environment that
  /// reports by file rather than by socket — `null` for every other one. Carried
  /// out of the sweep rather than recomputed by the drainer: a second spelling
  /// of a generated name is how an uninstall leaves something behind.
  final String? spoolDirectory;

  /// The distribution [spoolDirectory] lives in, so the drainer can tell
  /// whether it is worth listing. `null` outside WSL.
  final String? wslDistribution;
}

/// Writes Karmashala's status callbacks into the agents' own hook configs at
/// startup, and reports exactly what it did.
///
/// `awaitingApproval` and `failed` are hook-only states — no shipped CLI writes
/// them to a transcript in a form worth trusting — so everything downstream of
/// them is wired and inert without this.
///
/// Three properties it has to keep. **The file belongs to the user**: only the
/// `hooks` value is spliced back in, and our entries are marked. **The port is
/// ephemeral**, so this runs every launch — but what a launch rewrites is the
/// endpoint file, not the config, which is why [retireEndpoints] and not
/// [uninstallAll] runs on the way out. **Some agents cannot report at all**:
/// `127.0.0.1` inside WSL2 is that distribution's own loopback and the host side
/// of the WSL switch resets every byte sent to it, so a WSL agent gets a spool
/// directory instead of an address; SSH is always skipped and falls back to the
/// state-file and terminal-grid sources.
class AgentHookInstallationService {
  AgentHookInstallationService(
    this._ref, {
    AppLogger? logger,
    Duration? storeBudget,
  }) : _log = logger ?? AppLogger.named('agent-hooks'),
       _storeBudget = storeBudget ?? defaultStoreBudget;

  /// How long **one agent's sweep of one store home** may take before the app
  /// stops waiting for it and reports [AgentHookInstallation.unknown].
  ///
  /// Ten seconds rather than something tight, because the honest failure here is
  /// *slow*, not *broken*: the first touch of a WSL store home over the share
  /// **starts a stopped distribution**, and a cold plan9 daemon is seconds. What
  /// it rules out is the unbounded case — every file operation here used to be
  /// synchronous, and a synchronous Dart file operation has no timeout, so a
  /// share that stopped answering held the isolate and no report, log line or
  /// spool drain arrived for the rest of the run.
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

  /// Deletes every endpoint file [installAll] wrote, leaving the config entries
  /// and the scripts in place. **This is what runs on the way out.**
  ///
  /// The entry and the script are constants; the address and the token are not,
  /// and they die with this process. A config we do not rewrite is a config we
  /// cannot lose the race for. Unreachable environments are swept too — a file
  /// an earlier build wrote is still ours.
  Future<List<AgentHookInstallation>> retireEndpoints() => _forEachStore(
    verb: 'retire the endpoint for',
    skipUnreachable: false,
    act: (installer, descriptor, home, _) async =>
        installer.retireEndpoint(descriptor: descriptor, storeHome: home),
  );

  /// Removes every hook [installAll] wrote — entries, scripts and endpoint files
  /// alike.
  ///
  /// The complete removal, for a user who wants this app out of their agents'
  /// configuration and for the unreachable-environment sweep in [installAll].
  /// The *exit* path is [retireEndpoints], because taking the entry out twice a
  /// launch was itself the bug. Matches on [agentHookMarker] and never on the
  /// URL, which is what makes it survive an ephemeral port and a switch address
  /// that moved between boots.
  Future<List<AgentHookInstallation>> uninstallAll() => _forEachStore(
    verb: 'uninstall',
    skipUnreachable: false,
    act: (installer, descriptor, home, _) =>
        installer.uninstall(descriptor: descriptor, storeHome: home),
  );

  /// The install/uninstall walk: every located store, every hook-capable agent,
  /// one result row each. Written once because the two directions have to visit
  /// exactly the same files.
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
    final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
    if (environments.isEmpty) return const [];

    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final byId = {for (final e in environments) e.id: e};
    final installer = _ref.read(agentHookInstallerProvider);
    final registry = _ref.read(agentRegistryProvider);

    // **Every (agent, store home) pair at once.** The pairs are independent —
    // each agent declares its own `homeDirectoryName`, and two environments are
    // two filesystems — and in series one slow `\\wsl.localhost` share was the
    // whole sweep's cost and a hung one was the whole sweep. `Future.wait` keeps
    // the input order, so nothing downstream has to sort.
    final pending = <Future<AgentHookInstallation>>[];
    for (final store in stores) {
      final environment = byId[store.environmentId];
      final kind = environment?.kind;
      // An environment we have no row for is treated as unreachable rather than
      // guessed at: the wrong address here is a hook in someone's config that
      // silently never arrives. Asked once per store, outside the descriptor
      // loop, because the answer is a property of the environment.
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

  /// One (agent, store home) pair, with its own bound: one that does not answer
  /// inside [defaultStoreBudget] becomes a row saying so rather than a sweep
  /// that never finishes. The bound stops the **waiting**, not the work — a Dart
  /// future cannot be cancelled — which is harmless because every write is
  /// staged and renamed, so one that lands late still lands whole.
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

  /// The per-pair body [_forEachStore] runs concurrently. Never throws: every
  /// escape becomes a row, because a config we could not read is somebody's
  /// real file and the launch goes on without it.
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
      // Not just skipped — *cleaned*. An entry an earlier build wrote while the
      // address was still reachable keeps firing on every prompt: the owner
      // watched one print `curl: (52) Empty reply from server` into a live
      // session and fail the hook.
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
      // An agent that is not installed here has no store and nothing to
      // hook — the one `false` that is not a defect. Reporting it as one told
      // a Mac with the Antigravity IDE but not its CLI, on every launch, that
      // something was rewriting its config.
      final absent = !await installer.storeIsPresent(home);
      if (!applied && !absent && endpoint != null) {
        // An install that did not land, and a fact about disk rather than
        // intent since `install` reads the file back. It has to say so: the
        // "N installed, M skipped" count is the only place anyone would notice.
        _log.warning(
          'Wrote ${descriptor.id} hooks in ${describeEnvironmentId(environmentId)} but the '
          'config does not carry them; status falls back to the state '
          'file. Another process rewriting $home is the usual cause.',
        );
      }
      // Where this agent's payloads will land, for a transport that reports by
      // file. Asked of the installer rather than rebuilt here, so the drainer
      // and the uninstall sweep cannot disagree about the path.
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
        // absent agent is a fact about the agent, not the environment, and
        // folding it in told a Mac with two working agents and no Antigravity
        // CLI that it had no status callbacks at all.
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
