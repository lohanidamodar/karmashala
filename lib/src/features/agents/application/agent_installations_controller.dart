import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/database_providers.dart';
import 'package:karmashala_core/paths.dart';
import '../../../core/paths/path_probe_provider.dart';
import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import 'package:karmashala_core/util.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../data/agent_discovery_service.dart';
import '../data/agent_installation_dao.dart';
import '../data/agent_probe_log.dart';
import '../domain/agent_discovery_report.dart';
import '../domain/agent_installation.dart';
import '../domain/agent_path_repair.dart';
import '../domain/agent_registry.dart';
import '../domain/agent_version_reading.dart';
import 'agent_providers.dart';

/// Holds the known agent installations and can (re)discover them across every
/// known execution environment.
class AgentInstallationsController extends Notifier<List<AgentInstallation>> {
  @override
  List<AgentInstallation> build() =>
      ref.watch(agentInstallationDaoProvider).getAll();

  /// Re-probes every known environment and reconciles what is on record with
  /// what is actually installed, returning a truthful account of the run.
  ///
  /// This is the **recovery path**, and the only one. `discoverUnprobed` skips
  /// any `(agent, environment)` pair the [AgentProbeLog] says was ever searched
  /// for, found or not — which is what makes a single bad probe permanent. The
  /// bug this was written for: the app's first run recorded a miss for all
  /// three agents in `windows`, and every launch afterwards skipped Windows
  /// entirely, so `codex.exe` — sitting on the user PATH the whole time —
  /// stayed invisible with no way to ask again. So this method deliberately
  /// ignores the log and rewrites it from what it just saw.
  ///
  /// Reconciliation, per environment that actually answered:
  ///
  /// * an installation found and not on record is **added**;
  /// * one on record whose CLI now reports a different version is **updated in
  ///   place**, keeping its id;
  /// * one on record that this sweep asked about and did not find is
  ///   **removed** — the agent was uninstalled, or moved.
  ///
  /// An environment that could not be reached is reconciled against *nothing*.
  /// A stopped WSL distribution answers `command -v` exactly like a running one
  /// with no agents installed, so deleting on that evidence would throw away a
  /// working machine's agents because it happened to be shut down.
  Future<AgentDiscoveryReport> discoverAll() => _sweep();

  /// One reconciling sweep. [only] narrows it to specific agents per
  /// environment — `environmentId -> agentIds` — and null means every agent in
  /// every environment.
  ///
  /// The narrowing is what makes the startup repair affordable: a launch with
  /// one rotted row probes that one agent in that one environment rather than
  /// re-running the whole detection. Everything else about the run is
  /// identical, which is the point — the repair and Settings' "Detect agents"
  /// are the same code with a different scope, not two implementations that
  /// can drift.
  Future<AgentDiscoveryReport> _sweep({
    Map<String, Set<String>>? only,
  }) async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final factory = ref.read(commandRunnerFactoryProvider);
    final dao = ref.read(agentInstallationDaoProvider);
    final ids = ref.read(idGeneratorProvider);
    final clock = ref.read(clockProvider);
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(databaseProvider));
    final hostEnvironment = ref.read(hostEnvironmentProvider);
    final pathProbe = ref.read(pathProbeProvider);

    // **Every environment is asked at once; every environment is written in
    // order.** The probes are genuinely independent — a WSL distribution and a
    // Mac over SSH have nothing to say to each other, and each already
    // parallelises its own agents — but they were awaited one at a time, so the
    // New Session dialog's "rescan agents" spinner held for the sum of them
    // rather than the longest.
    //
    // The split is what makes it safe rather than merely faster. The *writes*
    // stay sequential and in the environments' own order: `_reconcile` mints
    // ids from one generator, `_readingsFor` re-reads the table each
    // environment's own reconcile has just written, and the probe log is a
    // database. Only the reaching-out is concurrent, so nothing about the
    // recorded outcome depends on which environment answered first.
    //
    // The number of probes is unchanged — one per environment the sweep is
    // scoped to, exactly as before; `agent_installations_controller_test.dart`
    // counts them.
    final asked = [
      for (final environment in environments)
        if (only == null ||
            (only[environment.id]?.isNotEmpty ?? false))
          (environment: environment, wanted: only?[environment.id]),
    ];
    final probes = await Future.wait([
      for (final one in asked) _probe(
        environment: one.environment,
        wanted: one.wanted,
        factory: factory,
        ids: ids,
        clock: clock,
        registry: registry,
        pathProbe: pathProbe,
        hostEnvironment: hostEnvironment,
      ),
    ]);

    final reports = <EnvironmentScanReport>[];
    for (var i = 0; i < asked.length; i++) {
      final environment = asked[i].environment;
      final wanted = asked[i].wanted;
      final probe = probes[i];

      if (probe == null || !probe.reachable) {
        reports.add(
          EnvironmentScanReport.unreachable(
            environmentId: environment.id,
            environmentName: environment.name,
            error:
                probe?.error ??
                _failures.remove(environment.id) ??
                'Environment did not respond.',
          ),
        );
        continue;
      }

      reports.add(
        _reconcile(
          environment: environment,
          probe: probe,
          dao: dao,
          ids: ids,
          clock: clock,
          registry: registry,
          readings: _readingsFor(environment, dao, pathProbe),
          probedIds: wanted,
        ),
      );

      // This walk asked about these agents, so [discoverUnprobed] need not ask
      // again. Only for an environment that answered, and only the agents that
      // were actually asked about: recording a probe we could not perform — or
      // did not perform, in a narrowed sweep — is what turns one bad moment
      // into a permanent state.
      if (environment.kind != EnvironmentKind.ssh) {
        for (final id
            in wanted ?? {for (final d in registry.descriptors) d.id}) {
          log.record(id, environment.id, clock.nowUtc());
        }
      }
    }
    _failures.clear();

    state = dao.getAll();
    return AgentDiscoveryReport(reports);
  }

  /// Why one environment could not even be asked, kept between [_sweep]'s two
  /// halves.
  ///
  /// A runner that cannot be *built* — an SSH environment with no configured
  /// connection — is a refusal with words on it, and those words are what the
  /// row shows. Carried here rather than raised, because a `Future.wait` fails
  /// on the first error and would throw away the answers of every environment
  /// that was perfectly reachable.
  final _failures = <String, String>{};

  /// One environment, asked. `null` when the runner could not be built at all;
  /// [_failures] then holds the reason.
  Future<EnvironmentProbe?> _probe({
    required ExecutionEnvironment environment,
    required Set<String>? wanted,
    required CommandRunnerFactory factory,
    required IdGenerator ids,
    required Clock clock,
    required AgentRegistry registry,
    required PathProbe pathProbe,
    required Map<String, String> hostEnvironment,
  }) async {
    try {
      return await AgentDiscoveryService(
        runner: factory.forEnvironment(environment),
        environment: environment,
        ids: ids,
        clock: clock,
        registry: registry,
        pathProbe: pathProbe,
        hostEnvironment: hostEnvironment,
      ).probeEnvironment(agentIds: wanted);
    } on Object catch (e) {
      _failures[environment.id] = '$e';
      return null;
    }
  }

  /// Brings the stored installations for one environment into line with what
  /// [probe] just found there.
  ///
  /// [readings] is what the local filesystem said about each stored row's
  /// executable, keyed by installation id, and it decides two things this used
  /// to get wrong:
  ///
  /// * a row whose executable is **unreachable** is never deleted. A junction
  ///   chain the OS will not traverse answers every probe exactly like an
  ///   uninstalled CLI, so deleting on that evidence turns "installed somewhere
  ///   I cannot reach" into "not installed" — the worse of the two, because it
  ///   takes the agent out of Settings and leaves nothing to correct;
  /// * a row whose path a **human set** and which still works is left exactly
  ///   as it is, even when the sweep found the agent somewhere else.
  ///
  /// [probedIds] narrows which stored rows this sweep is evidence about; null
  /// means the whole registry.
  EnvironmentScanReport _reconcile({
    required ExecutionEnvironment environment,
    required EnvironmentProbe probe,
    required AgentInstallationDao dao,
    required IdGenerator ids,
    required Clock clock,
    required AgentRegistry registry,
    required Map<String, ExecutableReading> readings,
    Set<String>? probedIds,
  }) {
    final stored = dao.getByEnvironment(environment.id);
    final added = <AgentInstallation>[];
    final updated = <AgentVersionChange>[];
    final movedPaths = <AgentPathChange>[];
    final pinnedPaths = <AgentInstallation>[];
    final unreachablePaths = <AgentInstallation>[];
    final present = <AgentInstallation>[];
    // Stored rows this sweep has already accounted for, so the leftover pass
    // below does not judge a row that was just moved or deliberately kept.
    final consumed = <String>{};

    // A hand-set path that was not *observed* broken is the user's answer to
    // "where is it", and a sweep does not overrule it. Unchecked counts as
    // working on purpose: a WSL or SSH path cannot be stat-ed from here, and
    // overwriting an explicit human choice on evidence we do not have is the
    // mistake, not keeping it.
    bool isPinned(AgentInstallation row) =>
        row.executableByUser && (readings[row.id]?.isUsable ?? true);

    for (final agent in probe.found) {
      final agentId = agent.descriptor.id;
      final path = agent.executable.path;

      final atThisPath = dao.getByIdentity(agentId, environment.id, path);
      if (atThisPath != null) {
        consumed.add(atThisPath.id);
        // Recorded whether or not the number moved: a sweep that confirms
        // 2.1.263 has taken a reading, and a reading with a stale timestamp
        // beside it is indistinguishable from one nobody has taken since.
        dao.recordVersion(atThisPath.id, agent.version, readAt: clock.nowUtc());
        if (agent.version != null && atThisPath.version != agent.version) {
          updated.add(
            AgentVersionChange(
              displayName: agent.descriptor.displayName,
              from: atThisPath.version,
              to: agent.version,
            ),
          );
        }
        present.add(_asRead(atThisPath, agent.version, clock));
        continue;
      }

      // The same agent in the same environment at a different path. Either the
      // user pinned it there, or it moved and this row follows it.
      final elsewhere = [
        for (final row in stored)
          if (row.agentId == agentId &&
              !consumed.contains(row.id) &&
              row.executable.path != path)
            row,
      ];
      final pinned = elsewhere.where(isPinned).toList();
      if (pinned.isNotEmpty) {
        // Not a second row for the same agent in the same environment: the
        // user already answered this question, and offering the choice again
        // is how an explicit decision gets quietly undone.
        consumed.add(pinned.first.id);
        pinnedPaths.add(pinned.first);
        present.add(pinned.first);
        continue;
      }

      final moved = elsewhere.isEmpty ? null : elsewhere.first;
      if (moved != null && dao.updatePath(moved.id, path, byUser: false)) {
        // **In place, keeping the id.** The id is what settings pin as the
        // default agent and what every session row references, so a CLI that
        // moved must stay the same installation. This used to delete the row
        // and insert a new one, repointing the sessions behind it — which
        // worked for the sessions and silently unpicked the default.
        consumed.add(moved.id);
        movedPaths.add(
          AgentPathChange(
            displayName: agent.descriptor.displayName,
            from: moved.executable.path,
            to: path,
          ),
        );
        dao.recordVersion(moved.id, agent.version, readAt: clock.nowUtc());
        if (agent.version != null && moved.version != agent.version) {
          updated.add(
            AgentVersionChange(
              displayName: agent.descriptor.displayName,
              from: moved.version,
              to: agent.version,
            ),
          );
        }
        present.add(
          _asRead(moved, agent.version, clock).copyWith(
            executable: agent.executable,
            executableByUser: false,
          ),
        );
        continue;
      }

      final installation = AgentInstallation(
        id: ids.newId(),
        agentId: agentId,
        executable: agent.executable,
        version: agent.version,
        versionReadAt: agent.version == null ? null : clock.nowUtc(),
        createdAt: clock.nowUtc(),
      );
      dao.insert(installation);
      added.add(installation);
      present.add(installation);
    }

    // Only rows for agents this sweep actually asked about. A stored row for a
    // descriptor the registry no longer carries — or one a narrowed sweep did
    // not probe — was not searched for, so nothing here is evidence about it:
    // it is left alone rather than tidied away.
    final probed =
        probedIds ??
        {for (final descriptor in registry.descriptors) descriptor.id};
    final removed = <AgentInstallation>[];
    final retained = <AgentInstallation>[];
    for (final row in stored) {
      if (consumed.contains(row.id)) continue;
      if (!probed.contains(row.agentId)) {
        present.add(row);
        continue;
      }
      if (isPinned(row)) {
        pinnedPaths.add(row);
        present.add(row);
        continue;
      }
      if (readings[row.id]?.reachability ==
          ExecutableReachability.unreachable) {
        // Not evidence of absence — see the doc above. Reported on its own and
        // counted among neither `found` nor `missing`, because the honest
        // answer is that the file is somewhere this machine will not go.
        unreachablePaths.add(row);
        continue;
      }

      // Genuinely uninstalled, and nothing replaced it. The row goes only if
      // nothing depends on it: `sessions` references it `ON DELETE RESTRICT`,
      // and that raise — thrown from the middle of this loop — used to abort
      // the entire sweep, so one uninstalled CLI left the app reporting no
      // agents in any environment at all.
      if (dao.deleteIfUnreferenced(row.id)) {
        removed.add(row);
      } else {
        retained.add(row);
      }
    }

    // An agent with an unreachable row is not "not installed": the sweep could
    // not complete the observation, so it does not get to state the outcome.
    final unreachableAgentIds = {
      for (final row in unreachablePaths) row.agentId,
    };
    return EnvironmentScanReport(
      environmentId: environment.id,
      environmentName: environment.name,
      reachable: true,
      found: present,
      missing: [
        for (final id in probe.missingAgentIds)
          if (!unreachableAgentIds.contains(id)) registry.displayNameFor(id),
      ],
      added: added,
      removed: removed,
      retained: retained,
      updated: updated,
      movedPaths: movedPaths,
      unreachablePaths: unreachablePaths,
      pinnedPaths: pinnedPaths,
    );
  }

  /// [row] as [recordVersion] just stored it — so the in-memory state and the
  /// database say the same thing about both the number and its age.
  ///
  /// A null [version] leaves the row untouched, matching the DAO: a probe that
  /// could not answer is not a reading.
  AgentInstallation _asRead(
    AgentInstallation row,
    String? version,
    Clock clock,
  ) => version == null
      ? row
      : row.copyWith(version: version, versionReadAt: clock.nowUtc());

  /// What the local filesystem says about each stored installation in
  /// [environment], keyed by installation id.
  ///
  /// Empty for an environment that is not this machine. A WSL or SSH path is
  /// spelled for *its* disk, so a stat of ours is not evidence about it either
  /// way — and a repair driven by a reading we could not take is the §19
  /// mistake with worse consequences, because it writes to the database.
  Map<String, ExecutableReading> _readingsFor(
    ExecutionEnvironment environment,
    AgentInstallationDao dao,
    PathProbe probe,
  ) {
    if (!isLocalHost(environment.kind)) return const {};
    final context = usesWindowsPaths(environment.kind) ? p.windows : p.posix;
    return {
      for (final row in dao.getByEnvironment(environment.id))
        row.id: readExecutable(row.executable.path, probe, context: context),
    };
  }

  /// Reads every stored installation's executable, newest reading wins.
  ///
  /// One stat per local row and nothing else — no subprocess, no `where`, no
  /// version probe. That is what makes it affordable on every launch, and it is
  /// the whole of the check when nothing is wrong.
  List<AgentPathReading> readStoredPaths() {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final probe = ref.read(pathProbeProvider);
    final byId = <String, ExecutableReading>{};
    for (final environment in ref
        .read(executionEnvironmentDaoProvider)
        .getAll()) {
      byId.addAll(_readingsFor(environment, dao, probe));
    }
    return [
      for (final row in dao.getAll())
        AgentPathReading(
          installation: row,
          displayName: registry.displayNameFor(row.agentId),
          reading:
              byId[row.id] ??
              ExecutableReading.unchecked(row.executable.path),
        ),
    ];
  }

  /// Checks every stored installation's executable and repairs the rows whose
  /// path no longer opens.
  ///
  /// **This is what the app was missing.** A stored path can rot without
  /// anything noticing: Codex self-updated to a versioned standalone layout and
  /// turned the stable path its own installer advertises into a chain of
  /// junctions Windows refuses to traverse, so every launch and every resume
  /// failed with a `ProcessException` and nothing in the app ever revisited the
  /// row. The path is durable *state*; whether it still resolves is a
  /// *measurement*, and a measurement taken once at first run is a measurement
  /// that expires.
  ///
  /// Cheap enough for every launch, and self-extinguishing: a workspace with
  /// nothing broken pays one `existsSync` per local installation — three, on the
  /// owner's machine — and spawns no processes at all. Only the rows that
  /// actually failed are re-probed, and only in their own environment.
  ///
  /// Repair is [_sweep] narrowed, so it is the same reconciliation Settings'
  /// "Detect agents" runs: the reparse-point resolver finds the executable
  /// behind the junction, the row follows it *keeping its id*, and the version
  /// is re-read from the binary that actually ran.
  ///
  /// **A repair that finds nothing changes nothing.** The row is kept — see
  /// [AgentPathRepairReport.unresolved] — because a row at a wrong path can be
  /// seen and corrected by hand, and no row at all cannot.
  ///
  /// [full] re-probes every agent in every environment instead of only the
  /// rows that failed. That is what Settings' "Detect agents" runs, and it is
  /// this same method rather than a second one on purpose: the button and the
  /// startup check must not be able to disagree about what a repair does.
  Future<AgentPathRepairReport> repairBrokenPaths({bool full = false}) async {
    final clock = ref.read(clockProvider);
    final broken = [
      for (final reading in readStoredPaths())
        if (reading.isBroken) reading,
    ];
    if (broken.isEmpty && !full) {
      return AgentPathRepairReport(checkedAt: clock.nowUtc());
    }

    final scope = <String, Set<String>>{};
    for (final reading in broken) {
      scope
          .putIfAbsent(reading.installation.environmentId, () => <String>{})
          .add(reading.installation.agentId);
    }
    final scan = await _sweep(only: full ? null : scope);

    // Re-read rather than infer: the sweep may have moved a row, replaced it,
    // or found nothing, and the filesystem is the only thing that can say which
    // of those actually left a usable executable behind.
    //
    // Keyed by **installation id**, which a repair now preserves — `updatePath`
    // moves the row rather than replacing it. Keying by `(agent, environment)`
    // would collapse two installations of the same agent in one environment
    // into a single row of the report.
    final after = {
      for (final reading in readStoredPaths())
        reading.installation.id: reading,
    };
    final repaired = <AgentPathReading>[];
    final unresolved = <AgentPathReading>[];
    for (final was in broken) {
      final now = after[was.installation.id];
      if (now == null) {
        // The row is gone: the sweep established the agent is not installed
        // here, which is a removal rather than an unrepaired path.
        continue;
      }
      (now.isUsable ? repaired : unresolved).add(now);
    }

    return AgentPathRepairReport(
      checkedAt: clock.nowUtc(),
      broken: broken,
      repaired: repaired,
      unresolved: unresolved,
      scan: scan,
    );
  }

  /// Re-reads the version of every stored installation whose recorded reading
  /// has aged out of [kVersionReadingFreshFor], in the row's **own**
  /// environment, and returns the numbers that actually moved.
  ///
  /// **The half §20 left out.** The launch check re-measures whether a stored
  /// path still resolves and never asks what is at the end of it: a version was
  /// written by the workspace's first scan and, because `discoverUnprobed`
  /// skips any pair that already has a row, only a manual "Detect agents" ever
  /// wrote it again. The app said Claude Code 2.1.252 for a binary answering
  /// 2.1.263, launch after launch. A path is state and whether it resolves is a
  /// measurement; a version is *entirely* a measurement, and these CLIs
  /// self-update — Codex went 0.145.0 to 0.153.4 mid-session.
  ///
  /// **Why the occasion is the launch and the gate is the row's age.** A
  /// version probe is a subprocess, and §19's third rule is that probes cost
  /// processes and nothing may poll. Re-reading on every launch would trade the
  /// property that makes the path check affordable; re-reading on every session
  /// start would spend a process per session for a number nobody is looking at.
  /// So the launch is *when we are allowed to ask* and the recorded reading
  /// decides *whether it is worth asking*: a workspace whose readings are all
  /// fresh spawns nothing at all, and a machine relaunched five times in an
  /// hour re-reads once. Neither cadence can make a bare number honest, which
  /// is why the age is stored and rendered — see [describeVersionReading].
  ///
  /// The rules are §20's, unchanged:
  ///
  /// * **judged in its own environment.** A WSL row is asked through the WSL
  ///   runner, so nothing local is stat-ed or spawned on its behalf; an **SSH**
  ///   row is not asked at all, because probing one means dialling somebody's
  ///   machine and a launch does not do that unasked. Its reading keeps its
  ///   age, which is the honest thing to show;
  /// * **no row is deleted on a failed reading.** An unreachable CLI answers
  ///   `Process.run` exactly like an uninstalled one;
  /// * **a local row whose executable was just observed missing is not spawned
  ///   at.** The process could only fail, and §20 already reports the path;
  /// * **nothing learned, nothing written.** A probe that could not answer
  ///   leaves the number *and* its timestamp alone, so the label still admits
  ///   the number may be wrong and the next launch tries again.
  ///
  /// Nothing here touches a path. A version reading is not evidence about where
  /// the executable is, and repairing that is [repairBrokenPaths]' job.
  Future<List<AgentVersionChange>> refreshStaleVersions() async {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final clock = ref.read(clockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final now = clock.nowUtc();

    final changes = <AgentVersionChange>[];
    for (final environment in ref
        .read(executionEnvironmentDaoProvider)
        .getAll()) {
      if (environment.kind == EnvironmentKind.ssh) continue;

      final candidates = [
        for (final row in dao.getByEnvironment(environment.id))
          if ((registry.byId(row.agentId)?.discovery.probeVersion ?? false) &&
              versionFreshness(row, now: now) != VersionFreshness.fresh)
            row,
      ];
      // Not even the stats: an environment with nothing to re-read is a
      // filesystem this method never touches.
      if (candidates.isEmpty) continue;

      // Empty for anything but this machine, which is what leaves a WSL row
      // ungated — a path spelled for its disk is not ours to judge.
      final readings = _readingsFor(environment, dao, ref.read(pathProbeProvider));

      final CommandRunner runner;
      try {
        runner = factory.forEnvironment(environment);
      } on Object {
        // An environment with no runner to build — a WSL row with no
        // distribution recorded. Nothing was established about it.
        continue;
      }

      for (final row in candidates) {
        if (readings[row.id]?.isUsable == false) continue;
        final version = await _readVersion(
          runner,
          row,
          registry.byId(row.agentId)!.discovery.versionArguments,
        );
        if (version == null) continue;
        dao.recordVersion(row.id, version, readAt: clock.nowUtc());
        if (version != row.version) {
          changes.add(
            AgentVersionChange(
              displayName: registry.displayNameFor(row.agentId),
              from: row.version,
              to: version,
            ),
          );
        }
      }
    }

    state = dao.getAll();
    return changes;
  }

  /// What the CLI at [row] answers, or null when it did not answer.
  ///
  /// One process, and only ever the executable already on record — no `where`,
  /// because the path is not in question here.
  ///
  /// Through the environment's [CommandRunner] and never `Process.run`, which
  /// is what keeps the creation off the isolate that draws: `Process.run` is
  /// charged to its caller before the future exists, and `ProcessSpawner` is
  /// the seam that moves it to a worker. See `core/process/process_spawn.dart`.
  Future<String?> _readVersion(
    CommandRunner runner,
    AgentInstallation row,
    List<String> versionArguments,
  ) async {
    try {
      final result = await runner.run(
        CommandRequest(
          executable: row.executable.path,
          arguments: versionArguments,
        ),
      );
      return result.ok ? parseAgentVersion(result.stdout) : null;
    } on CommandException {
      return null;
    }
  }

  /// Points one installation at [path], recording that a human chose it.
  ///
  /// The escape hatch for everything detection cannot see, and the reason it
  /// records *who* chose: a later sweep must not quietly move a path the user
  /// set deliberately. It still repairs it if it stops working — see
  /// [AgentInstallation.executableByUser].
  ///
  /// Returns false when another installation of the same agent in the same
  /// environment already holds [path], which the table forbids.
  bool setExecutablePath(String installationId, String path) {
    final dao = ref.read(agentInstallationDaoProvider);
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    final ok = dao.updatePath(installationId, trimmed, byUser: true);
    if (ok) state = dao.getAll();
    return ok;
  }

  /// Probes only the `(agent, environment)` pairs nobody has ever searched for,
  /// and returns the installations that search turned up.
  ///
  /// This is what makes an agent added by an *app upgrade* visible. Discovery
  /// used to run exactly once, when the workspace was created, so a descriptor
  /// that joined the registry later — `antigravity` in 1.1.4 — was invisible
  /// until the user happened to find "Discover agents" in Settings.
  ///
  /// **What counts as already searched**, in the order it is checked:
  ///
  /// * an installation row for that pair — the row is itself proof somebody
  ///   looked, and re-probing every known agent on every launch is the cost
  ///   this whole method exists to avoid;
  /// * an [AgentProbeLog] entry — which is how a *miss* stops repeating. An
  ///   agent that is genuinely not installed is searched for once, ever.
  ///
  /// SSH environments are skipped and, deliberately, **not** recorded as
  /// searched: probing one means dialling somebody's machine, which is not
  /// something a launch should do unasked, and pretending we looked would stop
  /// the manual per-environment scan from ever doing it.
  ///
  /// The cost is self-extinguishing. The first run after an upgrade spawns one
  /// process per genuinely-new pair; every run after that spawns none.
  Future<List<AgentInstallation>> discoverUnprobed() async {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(databaseProvider));
    final clock = ref.read(clockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final ids = ref.read(idGeneratorProvider);

    final discovered = <AgentInstallation>[];
    for (final environment
        in ref.read(executionEnvironmentDaoProvider).getAll()) {
      if (environment.kind == EnvironmentKind.ssh) continue;
      final known = {
        for (final install in dao.getByEnvironment(environment.id))
          install.agentId,
      };
      final missing = {
        for (final descriptor in registry.descriptors)
          if (!known.contains(descriptor.id) &&
              !log.hasProbed(descriptor.id, environment.id))
            descriptor.id,
      };
      // No runner, no subprocess, nothing: the common case after the first
      // sweep is an environment with nothing left to ask about.
      if (missing.isEmpty) continue;

      final found = await AgentDiscoveryService(
        runner: factory.forEnvironment(environment),
        environment: environment,
        ids: ids,
        clock: clock,
        registry: registry,
        pathProbe: ref.read(pathProbeProvider),
        hostEnvironment: ref.read(hostEnvironmentProvider),
      ).discover(agentIds: missing);

      for (final installation in found) {
        if (dao.getByIdentity(
              installation.agentId,
              installation.environmentId,
              installation.executable.path,
            ) ==
            null) {
          dao.insert(installation);
        }
        discovered.add(installation);
      }
      // Every pair that was actually asked about, found or not.
      for (final agentId in missing) {
        log.record(agentId, environment.id, clock.nowUtc());
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

/// Resolves the default installation to use from [installs]: the specific one
/// pinned by [defaultInstallationId] if still present, else the first
/// installation of [defaultAgentId], else `null`.
AgentInstallation? resolveDefaultInstallation(
  List<AgentInstallation> installs, {
  String? defaultInstallationId,
  String? defaultAgentId,
}) {
  if (defaultInstallationId != null) {
    for (final install in installs) {
      if (install.id == defaultInstallationId) return install;
    }
  }
  if (defaultAgentId != null) {
    for (final install in installs) {
      if (install.agentId == defaultAgentId) return install;
    }
  }
  return null;
}
