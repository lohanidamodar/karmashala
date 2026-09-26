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
/// **Credentials stay here.** A saved account's token bundle is written from
/// a client's save and read back only by `*.credentials`, answered to the
/// asking client; lists and changes carry every account without it. A saved
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

  AgentsSnapshot agents() => AgentsSnapshot(
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

  InstallationsReconciled reconcile(
    InstallationsReconcile request,
    List<DataChange> changes,
  ) {
    final environmentId = request.environmentId;
    if (_environments.getById(environmentId) == null) {
      throw DataRefused.notFound('no environment with id $environmentId');
    }
    for (final found in request.found) {
      if (found.environmentId != environmentId) {
        throw DataRefused.invalid(
          '${found.agentId} was found in ${found.environmentId}, '
          'not $environmentId',
        );
      }
      if (found.executable.path.trim().isEmpty) {
        throw DataRefused.invalid('${found.agentId} was found at no path');
      }
    }
    return _apply(
      planReconcile(
        environmentId: environmentId,
        stored: _installations.getByEnvironment(environmentId),
        found: request.found,
        probed: request.probed,
        readings: request.readings,
        readAt: request.readAt,
      ),
      request.readAt,
      changes,
    );
  }

  /// What the server found on this machine itself: recorded by the same
  /// rules, judging no leftover row — a CLI that has gone is the desktop's
  /// to reconcile with the person — and reading this machine's disk for the
  /// paths already recorded.
  InstallationsReconciled recordFound(
    ExecutionEnvironment here,
    List<AgentInstallation> found,
    DateTime readAt,
    List<DataChange> changes,
  ) {
    ensureEnvironment(here, changes);
    final stored = _installations.getByEnvironment(here.id);
    return _apply(
      planReconcile(
        environmentId: here.id,
        stored: stored,
        found: found,
        probed: const {},
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

  AgentInstallation recordVersion(
    InstallationVersion request,
    List<DataChange> changes,
  ) {
    _installation(request.id);
    if (request.version.trim().isEmpty) {
      throw const DataRefused.invalid('a version reading says something');
    }
    _installations.recordVersion(
      request.id,
      request.version,
      readAt: request.readAt,
    );
    return _installationChanged(request.id, changes);
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

  ClaudeAccount saveClaudeAccount(
    ClaudeAccountSave request,
    List<DataChange> changes,
  ) {
    final problem = claudeAccountProblem(request.account);
    if (problem != null) throw DataRefused.invalid(problem);
    final saved = claudeAccountWithoutCredentials(
      _claudeAccounts.upsert(request.account),
    );
    changes.add(ClaudeAccountChanged(saved));
    return saved;
  }

  ClaudeAccount claudeCredentials(ClaudeAccountCredentials request) =>
      _claudeAccounts.getById(request.id) ??
      (throw DataRefused.notFound('no saved Claude account ${request.id}'));

  DataAck deleteClaudeAccount(
    ClaudeAccountDelete request,
    List<DataChange> changes,
  ) {
    if (_claudeAccounts.getById(request.id) == null) return const DataAck();
    _claudeAccounts.delete(request.id);
    changes.add(ClaudeAccountRemoved(request.id));
    return const DataAck();
  }

  CodexAccount saveCodexAccount(
    CodexAccountSave request,
    List<DataChange> changes,
  ) {
    final problem = codexAccountProblem(request.account);
    if (problem != null) throw DataRefused.invalid(problem);
    final saved = codexAccountWithoutCredentials(
      _codexAccounts.upsert(request.account),
    );
    changes.add(CodexAccountChanged(saved));
    return saved;
  }

  CodexAccount codexCredentials(CodexAccountCredentials request) {
    for (final account in _codexAccounts.getAll()) {
      if (account.id == request.id) return account;
    }
    throw DataRefused.notFound('no saved Codex account ${request.id}');
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

  int recordUsage(UsageRecord request, List<DataChange> changes) {
    DateTime? at;
    for (final sample in request.samples) {
      if (sample.accountKey.trim().isEmpty || sample.windowLabel.isEmpty) {
        throw const DataRefused.invalid('a usage sample names its window');
      }
      if (at == null || sample.recordedAt.isAfter(at)) at = sample.recordedAt;
    }
    final gained = <String>{};
    var written = 0;
    _db.transaction(() {
      for (final sample in request.samples) {
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
