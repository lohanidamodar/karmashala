import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/data/data_providers.dart';
import '../../../core/util/agent_cli_bridge.dart';
import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/discovery.dart';
import '../data/agent_installation_dao.dart';
import '../data/agent_probe_log.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_providers.dart';
import '../../sessions/application/session_providers.dart';

/// Holds the known agent installations and can (re)discover them across every
/// known execution environment.
class AgentInstallationsController extends Notifier<List<AgentInstallation>> {
  @override
  List<AgentInstallation> build() =>
      ref.watch(agentInstallationDaoProvider).getAll();

  /// Reads the rows again: the server wrote some (its agent discovery on this
  /// machine, at start or on `agents.refresh`).
  void reload() => state = ref.read(agentInstallationDaoProvider).getAll();

  /// Re-probes and reconciles every environment — the **recovery path**, which
  /// ignores [AgentProbeLog]; an unreachable one reconciles against nothing.
  Future<AgentDiscoveryReport> discoverAll() => _sweep();

  /// One reconciling sweep; [only] narrows it to `environmentId -> agentIds`.
  /// The startup repair and "Detect agents" are this code at two scopes.
  Future<AgentDiscoveryReport> _sweep({Map<String, Set<String>>? only}) async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final factory = ref.read(commandRunnerFactoryProvider);
    final dao = ref.read(agentInstallationDaoProvider);
    final ids = ref.read(agentCliIdsProvider);
    final clock = ref.read(agentCliClockProvider);
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(appPreferencesProvider));
    final hostEnvironment = ref.read(hostEnvironmentProvider);
    final pathProbe = ref.read(agentCliPathProbeProvider);

    // Every environment at once, written back in order: awaiting them one at a
    // time held the rescan spinner for the sum rather than the longest.
    final asked = [
      for (final environment in environments)
        if (only == null || (only[environment.id]?.isNotEmpty ?? false))
          (environment: environment, wanted: only?[environment.id]),
    ];
    final probes = await Future.wait([
      for (final one in asked)
        _probe(
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

      // Only for an environment that answered, and only the agents actually
      // asked about: a probe we did not perform becomes a permanent state.
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

  /// Why one environment could not even be asked. Carried rather than raised,
  /// because a `Future.wait` fails on the first error and loses the rest.
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

  /// Reconciles one environment's rows against [probe]: an **unreachable**
  /// executable is never deleted, and a working human-set path is never moved.
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

    // A hand-set path not *observed* broken is the user's answer, and a sweep
    // does not overrule it. Unchecked counts as working: WSL cannot be stat-ed.
    bool isPinned(AgentInstallation row) =>
        row.executableByUser && (readings[row.id]?.isUsable ?? true);

    for (final agent in probe.found) {
      final agentId = agent.descriptor.id;
      final path = agent.executable.path;

      final atThisPath = dao.getByIdentity(agentId, environment.id, path);
      if (atThisPath != null) {
        consumed.add(atThisPath.id);
        // Recorded whether or not the number moved: a reading with a stale
        // timestamp is indistinguishable from one nobody has taken since.
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
        // Not a second row for the same agent here: the user already answered,
        // and asking again is how an explicit decision gets undone.
        consumed.add(pinned.first.id);
        pinnedPaths.add(pinned.first);
        present.add(pinned.first);
        continue;
      }

      final moved = elsewhere.isEmpty ? null : elsewhere.first;
      if (moved != null && dao.updatePath(moved.id, path, byUser: false)) {
        // **In place, keeping the id.** Settings pin the default agent by id,
        // so delete-and-insert silently unpicked the user's choice.
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
          _asRead(
            moved,
            agent.version,
            clock,
          ).copyWith(executable: agent.executable, executableByUser: false),
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

    // Only rows for agents this sweep actually asked about — a row it did not
    // probe was not searched for, so nothing here is evidence about it.
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
        // Not evidence of absence — see the doc above. Counted among neither
        // `found` nor `missing`.
        unreachablePaths.add(row);
        continue;
      }

      // Genuinely uninstalled. It goes only if nothing depends on it: that
      // `ON DELETE RESTRICT` raise used to abort the entire sweep.
      final sessionsName = ref
          .read(sessionsDataProvider)
          .getAll()
          .any((session) => session.agentInstallationId == row.id);
      if (!sessionsName && dao.deleteIfUnreferenced(row.id)) {
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

  /// [row] as [recordVersion] just stored it. A null [version] leaves the row
  /// untouched: a probe that could not answer is not a reading.
  AgentInstallation _asRead(
    AgentInstallation row,
    String? version,
    Clock clock,
  ) => version == null
      ? row
      : row.copyWith(version: version, versionReadAt: clock.nowUtc());

  /// What the local filesystem says about each stored installation here, keyed
  /// by id. Empty off this machine: a WSL path is spelled for *its* disk.
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

  /// Reads every stored installation's executable, newest reading wins. One
  /// stat per local row and no subprocess, which is why a launch can afford it.
  List<AgentPathReading> readStoredPaths() {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final probe = ref.read(agentCliPathProbeProvider);
    final byId = <String, ExecutableReading>{};
    for (final environment
        in ref.read(executionEnvironmentDaoProvider).getAll()) {
      byId.addAll(_readingsFor(environment, dao, probe));
    }
    return [
      for (final row in dao.getAll())
        AgentPathReading(
          installation: row,
          displayName: registry.displayNameFor(row.agentId),
          reading:
              byId[row.id] ?? ExecutableReading.unchecked(row.executable.path),
        ),
    ];
  }

  /// Repairs the stored rows whose path no longer opens — Codex's self-update
  /// hid its binary behind junctions. [full] re-probes everything instead.
  Future<AgentPathRepairReport> repairBrokenPaths({bool full = false}) async {
    final clock = ref.read(agentCliClockProvider);
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

    // Re-read rather than infer, and keyed by **installation id**: keying by
    // `(agent, environment)` would collapse two installations into one row.
    final after = {
      for (final reading in readStoredPaths()) reading.installation.id: reading,
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

  /// Re-reads the version of every row aged out of [kVersionReadingFreshFor],
  /// in its own environment; SSH is never asked, a failed read writes nothing.
  Future<List<AgentVersionChange>> refreshStaleVersions() async {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final clock = ref.read(agentCliClockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final now = clock.nowUtc();

    final changes = <AgentVersionChange>[];
    for (final environment
        in ref.read(executionEnvironmentDaoProvider).getAll()) {
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
      final readings = _readingsFor(
        environment,
        dao,
        ref.read(agentCliPathProbeProvider),
      );

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

  /// What the CLI at [row] answers, or null when it did not. Through the
  /// environment's [CommandRunner], never `Process.run`, which the UI pays for.
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

  /// Points one installation at [path] and records that a human chose it, so a
  /// sweep will not move it. False when another row already holds [path].
  bool setExecutablePath(String installationId, String path) {
    final dao = ref.read(agentInstallationDaoProvider);
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    final ok = dao.updatePath(installationId, trimmed, byUser: true);
    if (ok) state = dao.getAll();
    return ok;
  }

  /// Probes only the pairs nobody has ever searched for, which is what makes an
  /// agent added by an app upgrade visible. SSH is skipped and not recorded.
  Future<List<AgentInstallation>> discoverUnprobed() async {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(appPreferencesProvider));
    final clock = ref.read(agentCliClockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final ids = ref.read(agentCliIdsProvider);

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
        pathProbe: ref.read(agentCliPathProbeProvider),
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

/// The default installation from [installs]: [defaultInstallationId] if still
/// present, else the first of [defaultAgentId], else `null`.
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
