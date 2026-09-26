import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/data/data_providers.dart';
import '../../../core/util/agent_cli_bridge.dart';
import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/discovery.dart';
import '../data/agent_probe_log.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_environments/karmashala_environments.dart'
    show InstallationsReconciled;
import 'agent_providers.dart';

/// Holds the known agent installations — the server's, followed as they
/// change — and can (re)discover them across every known execution
/// environment. This app probes (it reaches WSL, SSH and this machine's
/// junctions); the server reconciles what it found with the rows by the one
/// rule (`planReconcile`) and writes them.
class AgentInstallationsController extends Notifier<List<AgentInstallation>> {
  AgentInstallationsData get _data => ref.read(agentInstallationsDataProvider);

  @override
  List<AgentInstallation> build() {
    final data = ref.watch(agentInstallationsDataProvider);
    final installations = data.getAll();
    final listening = data.changes.listen((_) => state = data.getAll());
    ref.onDispose(listening.cancel);
    return installations;
  }

  /// Re-probes and reconciles every environment — the **recovery path**, which
  /// ignores [AgentProbeLog]; an unreachable one reconciles against nothing.
  Future<AgentDiscoveryReport> discoverAll() => _sweep();

  /// One reconciling sweep; [only] narrows it to `environmentId -> agentIds`.
  /// The startup repair and "Detect agents" are this code at two scopes.
  Future<AgentDiscoveryReport> _sweep({Map<String, Set<String>>? only}) async {
    final environments = ref.read(environmentsDataProvider).getAll();
    final factory = ref.read(commandRunnerFactoryProvider);
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

      final probed =
          wanted ??
          {for (final descriptor in registry.descriptors) descriptor.id};
      final InstallationsReconciled written;
      try {
        written = await _data.reconcile(
          environmentId: environment.id,
          readAt: clock.nowUtc(),
          found: _candidates(probe, ids, clock),
          probed: probed,
          readings: {
            for (final entry in _readingsFor(environment, pathProbe).entries)
              entry.key: entry.value.reachability,
          },
        );
      } on DataRefused catch (refusal) {
        reports.add(
          EnvironmentScanReport.unreachable(
            environmentId: environment.id,
            environmentName: environment.name,
            error: 'The server did not record it: ${refusal.message}',
          ),
        );
        continue;
      }
      reports.add(_report(environment, probe, written, registry));

      // Only for an environment that answered, and only the agents actually
      // asked about: a probe we did not perform becomes a permanent state.
      if (environment.kind != EnvironmentKind.ssh) {
        for (final id in probed) {
          log.record(id, environment.id, clock.nowUtc());
        }
      }
    }
    _failures.clear();

    state = _data.getAll();
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

  /// What [probe] found, as the rows it would be if new.
  static List<AgentInstallation> _candidates(
    EnvironmentProbe probe,
    IdGenerator ids,
    Clock clock,
  ) => [
    for (final agent in probe.found)
      AgentInstallation(
        id: ids.newId(),
        agentId: agent.descriptor.id,
        executable: agent.executable,
        version: agent.version,
        versionReadAt: agent.version == null ? null : clock.nowUtc(),
        createdAt: clock.nowUtc(),
      ),
  ];

  /// What the server wrote for one environment, named for a person: an
  /// **unreachable** executable is never "not installed", and a working
  /// human-set path is reported as kept.
  static EnvironmentScanReport _report(
    ExecutionEnvironment environment,
    EnvironmentProbe probe,
    InstallationsReconciled written,
    AgentRegistry registry,
  ) {
    // An agent with an unreachable row is not "not installed": the sweep could
    // not complete the observation, so it does not get to state the outcome.
    final unreachableAgentIds = {
      for (final row in written.unreachable) row.agentId,
    };
    return EnvironmentScanReport(
      environmentId: environment.id,
      environmentName: environment.name,
      reachable: true,
      found: written.present,
      missing: [
        for (final id in probe.missingAgentIds)
          if (!unreachableAgentIds.contains(id)) registry.displayNameFor(id),
      ],
      added: written.added,
      removed: written.removed,
      retained: written.retained,
      updated: [
        for (final change in written.versionChanges)
          AgentVersionChange(
            displayName: registry.displayNameFor(change.agentId),
            from: change.from,
            to: change.to,
          ),
      ],
      movedPaths: [
        for (final change in written.pathChanges)
          AgentPathChange(
            displayName: registry.displayNameFor(change.agentId),
            from: change.from,
            to: change.to,
          ),
      ],
      unreachablePaths: written.unreachable,
      pinnedPaths: written.pinned,
    );
  }

  /// What the local filesystem says about each stored installation here, keyed
  /// by id. Empty off this machine: a WSL path is spelled for *its* disk.
  Map<String, ExecutableReading> _readingsFor(
    ExecutionEnvironment environment,
    PathProbe probe,
  ) {
    if (!isLocalHost(environment.kind)) return const {};
    final context = usesWindowsPaths(environment.kind) ? p.windows : p.posix;
    return {
      for (final row in _data.getByEnvironment(environment.id))
        row.id: readExecutable(row.executable.path, probe, context: context),
    };
  }

  /// Reads every stored installation's executable, newest reading wins. One
  /// stat per local row and no subprocess, which is why a launch can afford it.
  List<AgentPathReading> readStoredPaths() {
    final registry = ref.read(agentRegistryProvider);
    final probe = ref.read(agentCliPathProbeProvider);
    final byId = <String, ExecutableReading>{};
    for (final environment in ref.read(environmentsDataProvider).getAll()) {
      byId.addAll(_readingsFor(environment, probe));
    }
    return [
      for (final row in _data.getAll())
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
    final data = _data;
    final registry = ref.read(agentRegistryProvider);
    final clock = ref.read(agentCliClockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final now = clock.nowUtc();

    final changes = <AgentVersionChange>[];
    for (final environment in ref.read(environmentsDataProvider).getAll()) {
      if (environment.kind == EnvironmentKind.ssh) continue;

      final candidates = [
        for (final row in data.getByEnvironment(environment.id))
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
        try {
          await data.recordVersion(row.id, version, readAt: clock.nowUtc());
        } on DataRefused {
          continue;
        }
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

    state = data.getAll();
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
  Future<bool> setExecutablePath(String installationId, String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    try {
      await _data.setPath(installationId, trimmed);
    } on DataRefused {
      return false;
    }
    state = _data.getAll();
    return true;
  }

  /// Probes only the pairs nobody has ever searched for, which is what makes an
  /// agent added by an app upgrade visible. SSH is skipped and not recorded.
  Future<List<AgentInstallation>> discoverUnprobed() async {
    final data = _data;
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(appPreferencesProvider));
    final clock = ref.read(agentCliClockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final ids = ref.read(agentCliIdsProvider);

    final discovered = <AgentInstallation>[];
    for (final environment in ref.read(environmentsDataProvider).getAll()) {
      if (environment.kind == EnvironmentKind.ssh) continue;
      final known = {
        for (final install in data.getByEnvironment(environment.id))
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

      if (found.isNotEmpty) {
        try {
          await data.reconcile(
            environmentId: environment.id,
            readAt: clock.nowUtc(),
            found: found,
            // Nothing to judge: none of these agents had a row here.
            probed: const {},
          );
        } on DataRefused {
          // Not recorded, so not probed either: the next launch asks again.
          continue;
        }
      }
      discovered.addAll(found);
      // Every pair that was actually asked about, found or not.
      for (final agentId in missing) {
        log.record(agentId, environment.id, clock.nowUtc());
      }
    }

    state = data.getAll();
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
