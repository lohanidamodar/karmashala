import 'dart:io';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

/// Where agents run and who they run as, at the server — environments, saved
/// SSH hosts and the host keys trusted for them, agent installations, saved
/// accounts and the usage history: validates, applies the rules in
/// `karmashala_environments`, writes, and says what changed.
///
/// **Credentials stay here.** A saved account's token bundle is written when
/// the server captures it and read back only by the server, to switch an
/// installation to it; no answer, list or change carries it. A saved
/// SSH host's key *location* is answered to a client that asks for its hosts
/// and never told as a change (`SshHostTouched` names the host only). None of
/// it is logged: a refusal names what was wrong, never a value.
class HostsHandler {
  HostsHandler(this._db, this._now, {bool Function(String path)? opens})
    : _opens = opens ?? _fileOpens,
      _environments = ExecutionEnvironmentDao(_db),
      _sshHosts = SshHostDao(_db),
      _knownHosts = KnownHostDao(_db),
      _installations = AgentInstallationDao(_db),
      _claudeAccounts = ClaudeAccountDao(_db),
      _codexAccounts = CodexAccountDao(_db),
      _usage = UsageSampleDao(_db),
      _projects = ProjectDao(_db);

  static bool _fileOpens(String path) => File(path).existsSync();

  final AppDatabase _db;
  final DateTime Function() _now;

  /// Whether a path on this machine is a file — what the server's own sweep
  /// reads of the rows it records.
  final bool Function(String path) _opens;
  final ExecutionEnvironmentDao _environments;
  final SshHostDao _sshHosts;
  final KnownHostDao _knownHosts;
  final AgentInstallationDao _installations;
  final ClaudeAccountDao _claudeAccounts;
  final CodexAccountDao _codexAccounts;
  final UsageSampleDao _usage;
  final ProjectDao _projects;
  DateTime? _prunedAt;

  // Environments, SSH hosts and trusted keys.

  EnvironmentsSnapshot environments() => EnvironmentsSnapshot(
    environments: _environments.getAll(),
    sshHosts: _sshHosts.getAll(),
    knownHosts: _knownHosts.getAll(),
  );

  ExecutionEnvironment putEnvironment(
    EnvironmentPut request,
    List<DataChange> changes,
  ) {
    final environment = request.environment;
    final problem = environmentProblem(environment);
    if (problem != null) throw DataRefused.invalid(problem);
    final before = _environments.getById(environment.id);
    final kept = before == null
        ? environment
        // The row keeps when it was first recorded.
        : environment.copyWith(createdAt: before.createdAt);
    _environments.upsert(kept);
    final stored = _environments.getById(environment.id)!;
    if (stored != before) changes.add(EnvironmentChanged(stored));
    return stored;
  }

  /// Records this machine's environment unless it is there already — the
  /// server's own, before it records what it found here.
  void ensureEnvironment(
    ExecutionEnvironment environment,
    List<DataChange> changes,
  ) {
    if (_environments.ensure(environment)) {
      changes.add(EnvironmentChanged(_environments.getById(environment.id)!));
    }
  }

  SshHost putSshHost(SshHostPut request, List<DataChange> changes) {
    final host = request.host;
    final problem = sshHostProblem(host);
    if (problem != null) throw DataRefused.invalid(problem);
    final key = host.privateKey;
    if (key != null && _environments.getById(key.environmentId) == null) {
      throw DataRefused.notFound(
        'no environment with id ${key.environmentId} to read the key from',
      );
    }
    final before = _sshHosts.getById(host.id);
    final saved = before == null
        ? host
        : host.copyWith(createdAt: before.createdAt);
    _db.transaction(() {
      _sshHosts.upsert(saved);
      _environments.upsert(sshEnvironment(saved));
    });
    changes
      ..add(SshHostTouched(saved.id))
      ..add(EnvironmentChanged(_environments.getById(saved.environmentId)!));
    return _sshHosts.getById(saved.id)!;
  }

  DataAck deleteSshHost(SshHostDelete request, List<DataChange> changes) {
    final host =
        _sshHosts.getById(request.id) ??
        (throw DataRefused.notFound('no SSH host with id ${request.id}'));
    final environmentId = host.environmentId;
    final holding = _projects.namesUsingEnvironment(environmentId);
    if (holding.isNotEmpty) {
      throw DataRefused.invalid(
        '${host.name} is still used by ${holding.join(', ')}. '
        'Remove those projects first.',
      );
    }
    // `ON DELETE CASCADE`: its installations go with its environment.
    final installations = _installations.getByEnvironment(environmentId);
    _db.transaction(() {
      _environments.delete(environmentId);
      _sshHosts.delete(host.id);
    });
    changes
      ..add(SshHostRemoved(host.id))
      ..add(EnvironmentRemoved(environmentId))
      ..addAll([for (final i in installations) InstallationRemoved(i.id)]);
    return const DataAck();
  }

  KnownHostKey trustKey(KnownHostTrust request, List<DataChange> changes) {
    final asked = request.key;
    final problem = knownHostProblem(asked);
    if (problem != null) throw DataRefused.invalid(problem);
    final trusted = _knownHosts.find(asked.host, asked.port);
    final refusal = trustProblem(trusted, asked);
    if (refusal != null) throw DataRefused.invalid(refusal);
    // The same key again stays as it was first trusted.
    if (trusted != null) return trusted;
    _knownHosts.trust(
      KnownHostKey(
        host: asked.host,
        port: asked.port,
        keyType: asked.keyType,
        fingerprint: asked.fingerprint,
        trustedAt: _now(),
      ),
    );
    final stored = _knownHosts.find(asked.host, asked.port)!;
    changes.add(KnownHostChanged(stored));
    return stored;
  }

  DataAck forgetKey(KnownHostForget request, List<DataChange> changes) {
    if (_knownHosts.find(request.host, request.port) == null) {
      return const DataAck();
    }
    _knownHosts.forget(request.host, request.port);
    changes.add(KnownHostRemoved(request.host, request.port));
    return const DataAck();
  }

  // Installations.

  AgentsSnapshot agents({
    List<AccountUsageState> usage = const [],
    List<AcpAgentRow> acpAgents = const [],
  }) => AgentsSnapshot(
    usage: usage,
    acpAgents: acpAgents,
    installations: _installations.getAll(),
    claudeAccounts: [
      for (final a in _claudeAccounts.getAll())
        claudeAccountWithoutCredentials(a),
    ],
    codexAccounts: [
      for (final a in _codexAccounts.getAll())
        codexAccountWithoutCredentials(a),
    ],
  );

  /// Every installation recorded in [environmentId], oldest first.
  List<AgentInstallation> installationsIn(String environmentId) =>
      _installations.getByEnvironment(environmentId);

  /// Records a probe of [environmentId] by the one rule (`planReconcile`):
  /// [probed] names the agents asked about — only their leftover rows are
  /// judged — and [readings] what this machine's disk says of each row.
  InstallationsReconciled reconcile({
    required String environmentId,
    required DateTime readAt,
    required List<AgentInstallation> found,
    required Set<String> probed,
    required Map<String, ExecutableReachability> readings,
    required List<DataChange> changes,
  }) {
    if (_environments.getById(environmentId) == null) {
      throw DataRefused.notFound('no environment with id $environmentId');
    }
    for (final row in found) {
      if (row.environmentId != environmentId) {
        throw DataRefused.invalid(
          '${row.agentId} was found in ${row.environmentId}, '
          'not $environmentId',
        );
      }
      if (row.executable.path.trim().isEmpty) {
        throw DataRefused.invalid('${row.agentId} was found at no path');
      }
    }
    return _apply(
      planReconcile(
        environmentId: environmentId,
        stored: _installations.getByEnvironment(environmentId),
        found: found,
        probed: probed,
        readings: readings,
        readAt: readAt,
      ),
      readAt,
      changes,
    );
  }

  /// Every recorded installation, oldest first.
  List<AgentInstallation> allInstallations() => _installations.getAll();

  /// Every recorded environment.
  List<ExecutionEnvironment> allEnvironments() => _environments.getAll();

  /// What the server found on this machine itself: recorded by the same
  /// rules, judging no leftover row — a CLI that has gone is the desktop's
  /// to reconcile with the person — and reading this machine's disk for the
  /// paths already recorded. [forgotten] names the agent kinds the registry
  /// no longer knows: their rows are judged, and go when nothing points at
  /// them.
  InstallationsReconciled recordFound(
    ExecutionEnvironment here,
    List<AgentInstallation> found,
    DateTime readAt,
    List<DataChange> changes, {
    Set<String> forgotten = const {},
  }) {
    ensureEnvironment(here, changes);
    final stored = _installations.getByEnvironment(here.id);
    return _apply(
      planReconcile(
        environmentId: here.id,
        stored: stored,
        found: found,
        probed: forgotten,
        readings: {
          for (final row in stored)
            row.id: _opens(row.executable.path)
                ? ExecutableReachability.usable
                : ExecutableReachability.missing,
        },
        readAt: readAt,
      ),
      readAt,
      changes,
    );
  }

  InstallationsReconciled _apply(
    InstallationPlan plan,
    DateTime readAt,
    List<DataChange> changes,
  ) {
    final touched = <String>{};
    final removed = <AgentInstallation>[];
    final retained = <AgentInstallation>[];
    _db.transaction(() {
      plan.moves.forEach((id, path) {
        if (_installations.updatePath(id, path, byUser: false)) {
          touched.add(id);
        }
      });
      plan.versions.forEach((id, version) {
        _installations.recordVersion(id, version, readAt: readAt);
        touched.add(id);
      });
      for (final row in plan.inserts) {
        _installations.insert(row);
        touched.add(row.id);
      }
    });
    // Not in the transaction: a row something still points at is refused by
    // the schema (`ON DELETE RESTRICT`), and that refusal is an answer.
    for (final row in plan.absent) {
      if (_installations.deleteIfUnreferenced(row.id)) {
        removed.add(row);
        changes.add(InstallationRemoved(row.id));
      } else {
        retained.add(row);
      }
    }
    for (final id in touched) {
      if (_installations.getById(id) case final row?) {
        changes.add(InstallationChanged(row));
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

  /// Records what installation [id]'s CLI answered, read at [readAt].
  AgentInstallation recordVersion(
    String id,
    String version,
    DateTime readAt,
    List<DataChange> changes,
  ) {
    _installation(id);
    if (version.trim().isEmpty) {
      throw const DataRefused.invalid('a version reading says something');
    }
    _installations.recordVersion(id, version, readAt: readAt);
    return _installationChanged(id, changes);
  }

  AgentInstallation setPath(
    InstallationSetPath request,
    List<DataChange> changes,
  ) {
    final row = _installation(request.id);
    final path = request.path.trim();
    if (path.isEmpty) {
      throw const DataRefused.invalid('An executable needs a path.');
    }
    if (installationPathTaken(
      _installations.getByEnvironment(row.environmentId),
      row,
      path,
    )) {
      throw DataRefused.invalid(
        'Another ${row.agentId} installation there is already $path.',
      );
    }
    if (!_installations.updatePath(row.id, path, byUser: true)) {
      throw DataRefused.invalid('$path is recorded for another installation.');
    }
    return _installationChanged(row.id, changes);
  }

  AgentInstallation _installation(String id) =>
      _installations.getById(id) ??
      (throw DataRefused.notFound('no agent installation with id $id'));

  AgentInstallation _installationChanged(String id, List<DataChange> changes) {
    final row = _installation(id);
    changes.add(InstallationChanged(row));
    return row;
  }

  // Saved accounts.

  /// Saves a Claude account the server captured — the one with the same
  /// email and organization keeps its id. Answers it without credentials.
  ClaudeAccount saveClaudeAccount(
    ClaudeAccount account,
    List<DataChange> changes,
  ) {
    final problem = claudeAccountProblem(account);
    if (problem != null) throw DataRefused.invalid(problem);
    final saved = claudeAccountWithoutCredentials(
      _claudeAccounts.upsert(account),
    );
    changes.add(ClaudeAccountChanged(saved));
    return saved;
  }

  /// Saved Claude account [id] **with** its credentials — the server's own
  /// read, right before it switches an installation to it.
  ClaudeAccount claudeAccount(String id) =>
      _claudeAccounts.getById(id) ??
      (throw DataRefused.notFound('no saved Claude account $id'));

  DataAck deleteClaudeAccount(
    ClaudeAccountDelete request,
    List<DataChange> changes,
  ) {
    if (_claudeAccounts.getById(request.id) == null) return const DataAck();
    _claudeAccounts.delete(request.id);
    changes.add(ClaudeAccountRemoved(request.id));
    return const DataAck();
  }

  /// Saves a Codex account the server captured — the one with the same
  /// account id keeps its id. Answers it without credentials.
  CodexAccount saveCodexAccount(
    CodexAccount account,
    List<DataChange> changes,
  ) {
    final problem = codexAccountProblem(account);
    if (problem != null) throw DataRefused.invalid(problem);
    final saved = codexAccountWithoutCredentials(
      _codexAccounts.upsert(account),
    );
    changes.add(CodexAccountChanged(saved));
    return saved;
  }

  /// Saved Codex account [id] **with** its credentials, for a switch.
  CodexAccount codexAccount(String id) {
    for (final account in _codexAccounts.getAll()) {
      if (account.id == id) return account;
    }
    throw DataRefused.notFound('no saved Codex account $id');
  }

  DataAck deleteCodexAccount(
    CodexAccountDelete request,
    List<DataChange> changes,
  ) {
    final known = _codexAccounts.getAll().any((a) => a.id == request.id);
    if (!known) return const DataAck();
    _codexAccounts.delete(request.id);
    changes.add(CodexAccountRemoved(request.id));
    return const DataAck();
  }

  // Usage history.

  /// Records one reading's candidate samples (`usageSamplesOf`): keeps what
  /// is worth a row and prunes at most hourly by the readings' own clock.
  int recordUsage(List<UsageSample> samples, List<DataChange> changes) {
    DateTime? at;
    for (final sample in samples) {
      if (sample.accountKey.trim().isEmpty || sample.windowLabel.isEmpty) {
        throw const DataRefused.invalid('a usage sample names its window');
      }
      if (at == null || sample.recordedAt.isAfter(at)) at = sample.recordedAt;
    }
    final gained = <String>{};
    var written = 0;
    _db.transaction(() {
      for (final sample in samples) {
        final last = _usage.latest(sample.accountKey, sample.windowLabel);
        if (!usageSampleWorthKeeping(sample, last)) continue;
        _usage.insert(sample);
        gained.add(sample.accountKey);
        written++;
      }
    });
    // Pruned by the readings' own clock, at most once an hour.
    final pruned = _prunedAt;
    if (at != null &&
        (pruned == null || at.difference(pruned) >= kUsageHistoryPruneEvery)) {
      _usage.prune(
        now: at,
        keep: kUsageHistoryKeep,
        fullResolution: kUsageHistoryFullResolution,
      );
      _prunedAt = at;
    }
    changes.addAll(gained.map(UsageRecorded.new));
    return written;
  }

  List<UsageSample> usageHistory(UsageHistory request) =>
      _usage.since(request.accountKey, request.since);
}
