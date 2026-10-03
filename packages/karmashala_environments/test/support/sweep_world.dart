import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_environments/sweep.dart';

import 'fakes.dart';
import 'fixtures.dart';

/// The recorded installations, in memory, written the way the server writes
/// them: [reconcile] applies `planReconcile` exactly as `HostsHandler`'s
/// `reconcile`/`_apply` do — the moves, then the versions, then the inserts,
/// all or nothing; then each absent row is removed unless something still
/// points at it ([referenced], the fake's `ON DELETE RESTRICT`).
class MemoryInstallations {
  MemoryInstallations(this._environments);

  final List<ExecutionEnvironment> Function() _environments;
  final _rows = <AgentInstallation>[];

  /// Installation ids a session (or anything else) still points at.
  final referenced = <String>{};

  /// When set, [reconcile] refuses with it — the server saying no.
  Object? refuseReconcile;

  /// Every installation, oldest first (the table's `created_at, id`).
  List<AgentInstallation> getAll() => [..._rows]
    ..sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });

  List<AgentInstallation> getByEnvironment(String environmentId) => [
    for (final row in getAll())
      if (row.environmentId == environmentId) row,
  ];

  AgentInstallation? getById(String id) {
    for (final row in _rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  void insert(AgentInstallation row) {
    if (getById(row.id) != null) {
      throw StateError('an installation with id ${row.id} exists');
    }
    if (installationPathTaken(_rows, row, row.executable.path)) {
      throw StateError('${row.executable.path} is already recorded');
    }
    _rows.add(row);
  }

  void _replace(AgentInstallation row) =>
      _rows[_rows.indexWhere((r) => r.id == row.id)] = row;

  Future<InstallationsReconciled> reconcile({
    required String environmentId,
    required DateTime readAt,
    required List<AgentInstallation> found,
    required Set<String> probed,
    required Map<String, ExecutableReachability> readings,
  }) async {
    if (refuseReconcile case final refusal?) throw refusal;
    if (!_environments().any((e) => e.id == environmentId)) {
      throw StateError('no environment with id $environmentId');
    }
    for (final row in found) {
      if (row.environmentId != environmentId) {
        throw StateError('${row.agentId} was found in ${row.environmentId}');
      }
      if (row.executable.path.trim().isEmpty) {
        throw StateError('${row.agentId} was found at no path');
      }
    }
    final plan = planReconcile(
      environmentId: environmentId,
      stored: getByEnvironment(environmentId),
      found: found,
      probed: probed,
      readings: readings,
      readAt: readAt,
    );

    // The transaction: all of it lands, or none of it does.
    final before = [..._rows];
    try {
      plan.moves.forEach((id, path) {
        final row = getById(id)!;
        // `updatePath` answers false for a path another row holds.
        if (installationPathTaken(_rows, row, path)) return;
        _replace(installationAt(row, path, byUser: false));
      });
      plan.versions.forEach((id, version) {
        final row = getById(id);
        if (row == null) return;
        _replace(row.copyWith(version: version, versionReadAt: readAt));
      });
      plan.leadingArguments.forEach((id, arguments) {
        final row = getById(id);
        if (row == null) return;
        _replace(row.copyWith(leadingArguments: arguments));
      });
      plan.inserts.forEach(insert);
    } on Object {
      _rows
        ..clear()
        ..addAll(before);
      rethrow;
    }

    final removed = <AgentInstallation>[];
    final retained = <AgentInstallation>[];
    for (final row in plan.absent) {
      if (referenced.contains(row.id)) {
        retained.add(row);
      } else {
        _rows.removeWhere((r) => r.id == row.id);
        removed.add(row);
      }
    }
    return InstallationsReconciled(
      present: plan.present,
      added: plan.inserts,
      removed: removed,
      retained: retained,
      pinned: plan.pinned,
      unreachable: plan.unreachable,
      versionChanges: plan.versionChanges,
      pathChanges: plan.pathChanges,
    );
  }

  /// What the server's `recordVersion` does: an unknown id or an empty
  /// reading is refused.
  Future<void> recordVersion(String id, String version, DateTime readAt) async {
    final row = getById(id);
    if (row == null) throw StateError('no installation with id $id');
    if (version.trim().isEmpty) throw StateError('an empty version');
    _replace(row.copyWith(version: version, versionReadAt: readAt));
  }
}

/// One machine's worth of state for an [AgentSweep]: the environments, the
/// installations and the probe log, all in memory.
class SweepWorld {
  SweepWorld([List<ExecutionEnvironment> environments = const []])
    : environments = [...environments] {
    installations = MemoryInstallations(() => this.environments);
  }

  final List<ExecutionEnvironment> environments;
  late final MemoryInstallations installations;

  /// The probe log's JSON, as the server's metadata would hold it.
  String? probeLogJson;

  AgentProbeLog get probeLog => AgentProbeLog(
    read: () => probeLogJson,
    write: (json) => probeLogJson = json,
  );

  /// Upserts [environment] by id, keeping the table's order.
  void addEnvironment(ExecutionEnvironment environment) {
    final at = environments.indexWhere((e) => e.id == environment.id);
    if (at < 0) {
      environments.add(environment);
    } else {
      environments[at] = environment;
    }
  }

  /// The sweep over this world. [runnerFor] answers for every environment;
  /// the path probe is always a described disk — never this machine's.
  AgentSweep sweep({
    required CommandRunner Function(ExecutionEnvironment environment) runnerFor,
    PathProbe? pathProbe,
    Clock? clock,
    AgentRegistry registry = AgentRegistry.builtIn,
    AgentRegistry Function()? registryNow,
    AcpVersionReader? readAcpVersion,
    Map<String, String> hostEnvironment = const {},
  }) => AgentSweep(
    environments: () => [...environments],
    installations: installations.getAll,
    reconcile: installations.reconcile,
    recordVersion: installations.recordVersion,
    runnerFor: runnerFor,
    probeLog: probeLog,
    ids: SequentialIdGenerator(),
    clock: clock ?? FixedClock(testTime),
    registry: registry,
    registryNow: registryNow,
    readAcpVersion: readAcpVersion,
    pathProbe: pathProbe ?? FakePathProbe(),
    hostEnvironment: hostEnvironment,
  );
}
