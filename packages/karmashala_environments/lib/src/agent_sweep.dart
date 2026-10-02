import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import 'installation_rules.dart';

/// Records a probe of one environment by the one rule (`planReconcile`):
/// [probed] names the agents asked about, [readings] what this machine's
/// disk says of each recorded path.
typedef SweepReconcile =
    Future<InstallationsReconciled> Function({
      required String environmentId,
      required DateTime readAt,
      required List<AgentInstallation> found,
      required Set<String> probed,
      required Map<String, ExecutableReachability> readings,
    });

/// Which `(agent, environment)` pairs have ever been *searched* for — never
/// looked for is not the same as looked for and not found. Kept as JSON under
/// one key by whoever holds it ([read] / [write]).
class AgentProbeLog {
  const AgentProbeLog({required this.read, required this.write});

  /// The key it lives under in the server's metadata.
  static const key = 'agents_probed';

  final String? Function() read;
  final void Function(String json) write;

  /// `agentId -> environmentId -> when it was last searched for`.
  Map<String, Map<String, String>> entries() {
    final raw = read();
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: {
              for (final inner in (entry.value as Map).entries)
                if (inner.key is String && inner.value is String)
                  inner.key as String: inner.value as String,
            },
      };
    } on FormatException {
      return {};
    }
  }

  bool hasProbed(String agentId, String environmentId) =>
      entries()[agentId]?.containsKey(environmentId) ?? false;

  /// Records that [agentId] was searched for in [environmentId], found or not.
  /// A miss is the valuable half: it stops the next start spawning again.
  void record(String agentId, String environmentId, DateTime at) {
    final log = entries();
    final forAgent = {...?log[agentId], environmentId: at.toIso8601String()};
    write(jsonEncode({...log, agentId: forAgent}));
  }
}

/// **Finding the agent CLIs**, in every environment the caller can run
/// commands in, and keeping their recorded rows true: the sweep (every
/// environment, or some agents in some), one environment's add-only scan,
/// the check-and-repair of rotted paths, the re-read of aged versions, and
/// the discovery of pairs nobody has searched yet. The server runs it on its
/// own machine; nothing here names an agent — the registry's adapters say
/// which there are and how to read them.
class AgentSweep {
  AgentSweep({
    required this.environments,
    required this.installations,
    required this.reconcile,
    required this.recordVersion,
    required this.runnerFor,
    required this.probeLog,
    required this.ids,
    required this.clock,
    AgentRegistry registry = AgentRegistry.builtIn,
    this.registryNow,
    this.pathProbe = const LocalPathProbe(),
    this.hostEnvironment = const {},
  }) : initialRegistry = registry;

  /// Every recorded environment, in the table's order.
  final List<ExecutionEnvironment> Function() environments;

  /// Every recorded installation.
  final List<AgentInstallation> Function() installations;

  final SweepReconcile reconcile;

  /// Records what installation `id`'s CLI answered, read at `readAt`.
  final Future<void> Function(String id, String version, DateTime readAt)
  recordVersion;

  /// How to run a command in an environment; throws when it cannot.
  final CommandRunner Function(ExecutionEnvironment environment) runnerFor;

  final AgentProbeLog probeLog;
  final IdGenerator ids;
  final Clock clock;

  /// The registry when nobody supplies [registryNow].
  final AgentRegistry initialRegistry;

  /// The registry as it stands now, when it can change while the server
  /// runs.
  final AgentRegistry Function()? registryNow;

  /// The agents a sweep probes, read at each sweep: an agent a person adds
  /// while the server runs is probed by the next one, not after a restart.
  AgentRegistry get registry => registryNow?.call() ?? initialRegistry;

  /// Reads this machine's filesystem, junction chains and all.
  final PathProbe pathProbe;

  /// This process's environment, which a local probe hands on.
  final Map<String, String> hostEnvironment;

  List<AgentInstallation> _in(String environmentId) => [
    for (final row in installations())
      if (row.environmentId == environmentId) row,
  ];

  /// Re-probes and reconciles every environment ([only] narrows it to
  /// `environmentId -> agentIds`); an unreachable one reconciles nothing.
  Future<AgentDiscoveryReport> sweep({Map<String, Set<String>>? only}) async {
    final asked = [
      for (final environment in environments())
        if (only == null || (only[environment.id]?.isNotEmpty ?? false))
          (environment: environment, wanted: only?[environment.id]),
    ];
    // Every environment at once: awaiting them in turn costs the sum rather
    // than the longest.
    final probes = await Future.wait([
      for (final one in asked) _probe(one.environment, one.wanted),
    ]);

    final reports = <EnvironmentScanReport>[];
    for (var i = 0; i < asked.length; i++) {
      final environment = asked[i].environment;
      final probe = probes[i];
      if (!probe.reachable) {
        reports.add(
          EnvironmentScanReport.unreachable(
            environmentId: environment.id,
            environmentName: environment.name,
            error: probe.error ?? 'Environment did not respond.',
          ),
        );
        continue;
      }
      final probed =
          asked[i].wanted ??
          {for (final descriptor in registry.descriptors) descriptor.id};
      final InstallationsReconciled written;
      try {
        written = await reconcile(
          environmentId: environment.id,
          readAt: clock.nowUtc(),
          found: _candidates(probe),
          // A kind the registry forgot is judged with the ones asked about:
          // it was found nowhere, so its row goes.
          probed: {
            ...probed,
            ...forgottenAgentKinds(registry, _in(environment.id)),
          },
          readings: {
            for (final entry in _readingsFor(environment).entries)
              entry.key: entry.value.reachability,
          },
        );
      } on Object catch (error) {
        reports.add(
          EnvironmentScanReport.unreachable(
            environmentId: environment.id,
            environmentName: environment.name,
            error: 'It was not recorded: $error',
          ),
        );
        continue;
      }
      reports.add(_report(environment, probe, written));
      // Only for an environment that answered, and only the agents actually
      // asked about: a probe not performed would become a permanent state.
      if (environment.kind != EnvironmentKind.ssh) {
        for (final id in probed) {
          probeLog.record(id, environment.id, clock.nowUtc());
        }
      }
    }
    return AgentDiscoveryReport(reports);
  }

  /// Probes [environment] alone and records what answered; no row it did not
  /// find is judged — a remote host's one failure belongs to it alone.
  Future<AgentDiscoveryReport> scan(ExecutionEnvironment environment) async {
    final probe = await _probe(environment, null);
    if (!probe.reachable) {
      return AgentDiscoveryReport([
        EnvironmentScanReport.unreachable(
          environmentId: environment.id,
          environmentName: environment.name,
          error: probe.error ?? 'Environment did not respond.',
        ),
      ]);
    }
    final written = await reconcile(
      environmentId: environment.id,
      readAt: clock.nowUtc(),
      found: _candidates(probe),
      probed: const {},
      readings: const {},
    );
    return AgentDiscoveryReport([_report(environment, probe, written)]);
  }

  Future<EnvironmentProbe> _probe(
    ExecutionEnvironment environment,
    Set<String>? wanted,
  ) async {
    try {
      return await AgentDiscoveryService(
        runner: runnerFor(environment),
        environment: environment,
        ids: ids,
        clock: clock,
        registry: registry,
        pathProbe: pathProbe,
        hostEnvironment: hostEnvironment,
      ).probeEnvironment(agentIds: wanted);
    } on Object catch (error) {
      return EnvironmentProbe(
        found: const [],
        missingAgentIds: const [],
        reachable: false,
        error: '$error',
      );
    }
  }

  List<AgentInstallation> _candidates(EnvironmentProbe probe) => [
    for (final agent in probe.found)
      AgentInstallation(
        id: ids.newId(),
        agentId: agent.descriptor.id,
        executable: agent.executable,
        version: agent.version,
        versionReadAt: agent.version == null ? null : clock.nowUtc(),
        createdAt: clock.nowUtc(),
        leadingArguments: agent.leadingArguments,
      ),
  ];

  /// What was written for one environment, named for a person: an
  /// **unreachable** executable is never "not installed", and a working
  /// human-set path is reported as kept.
  EnvironmentScanReport _report(
    ExecutionEnvironment environment,
    EnvironmentProbe probe,
    InstallationsReconciled written,
  ) {
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

  /// What this machine's filesystem says about each recorded installation in
  /// [environment], by id. Empty off this machine: a WSL or SSH path is
  /// spelled for *its* disk.
  Map<String, ExecutableReading> _readingsFor(
    ExecutionEnvironment environment,
  ) {
    if (!isLocalHost(environment.kind)) return const {};
    final context = usesWindowsPaths(environment.kind) ? p.windows : p.posix;
    return {
      for (final row in _in(environment.id))
        row.id: readExecutable(
          row.executable.path,
          pathProbe,
          context: context,
        ),
    };
  }

  /// Every recorded executable, read — one stat per local row and no
  /// subprocess; rows elsewhere are unchecked.
  List<AgentPathReading> readStoredPaths() {
    final byId = <String, ExecutableReading>{};
    for (final environment in environments()) {
      byId.addAll(_readingsFor(environment));
    }
    return [
      for (final row in installations())
        AgentPathReading(
          installation: row,
          displayName: registry.displayNameFor(row.agentId),
          reading:
              byId[row.id] ?? ExecutableReading.unchecked(row.executable.path),
        ),
    ];
  }

  /// Repairs the recorded rows whose path no longer opens — a self-update
  /// that hid its binary behind junctions. [full] re-probes everything.
  Future<AgentPathRepairReport> repairBrokenPaths({bool full = false}) async {
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
    final scan = await sweep(only: full ? null : scope);

    // Re-read rather than infer, keyed by installation id: keying by
    // `(agent, environment)` would collapse two installations into one.
    final after = {
      for (final reading in readStoredPaths()) reading.installation.id: reading,
    };
    final repaired = <AgentPathReading>[];
    final unresolved = <AgentPathReading>[];
    for (final was in broken) {
      final now = after[was.installation.id];
      // Gone: the sweep established it is not installed there.
      if (now == null) continue;
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
    final now = clock.nowUtc();
    final changes = <AgentVersionChange>[];
    for (final environment in environments()) {
      if (environment.kind == EnvironmentKind.ssh) continue;
      final candidates = [
        for (final row in _in(environment.id))
          if ((registry.byId(row.agentId)?.discovery.probeVersion ?? false) &&
              versionFreshness(row, now: now) != VersionFreshness.fresh)
            row,
      ];
      if (candidates.isEmpty) continue;
      final readings = _readingsFor(environment);
      final CommandRunner runner;
      try {
        runner = runnerFor(environment);
      } on Object {
        // Nothing to run it in (a WSL row with no distribution): nothing was
        // established about it.
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
          await recordVersion(row.id, version, clock.nowUtc());
        } on Object {
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
    return changes;
  }

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

  /// Probes only the pairs nobody has ever searched for, which is what makes
  /// an agent a newer build knows visible. SSH is skipped and not recorded.
  Future<List<AgentInstallation>> discoverUnprobed() async {
    final discovered = <AgentInstallation>[];
    for (final environment in environments()) {
      if (environment.kind == EnvironmentKind.ssh) continue;
      final known = {for (final row in _in(environment.id)) row.agentId};
      final missing = {
        for (final descriptor in registry.descriptors)
          if (!known.contains(descriptor.id) &&
              !probeLog.hasProbed(descriptor.id, environment.id))
            descriptor.id,
      };
      if (missing.isEmpty) continue;
      final List<AgentInstallation> found;
      try {
        found = await AgentDiscoveryService(
          runner: runnerFor(environment),
          environment: environment,
          ids: ids,
          clock: clock,
          registry: registry,
          pathProbe: pathProbe,
          hostEnvironment: hostEnvironment,
        ).discover(agentIds: missing);
      } on Object {
        continue;
      }
      if (found.isNotEmpty) {
        try {
          await reconcile(
            environmentId: environment.id,
            readAt: clock.nowUtc(),
            found: found,
            // Nothing to judge: none of these agents had a row here.
            probed: const {},
            readings: const {},
          );
        } on Object {
          // Not recorded, so not probed either: the next start asks again.
          continue;
        }
      }
      discovered.addAll(found);
      for (final agentId in missing) {
        probeLog.record(agentId, environment.id, clock.nowUtc());
      }
    }
    return discovered;
  }
}
