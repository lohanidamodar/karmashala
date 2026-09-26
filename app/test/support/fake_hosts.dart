part of 'fake_data_server.dart';

/// Where agents run and who they run as, in a [FakeDataServer]: the
/// environments, saved SSH hosts, trusted host keys, agent installations,
/// saved accounts and the usage history — each table shaped like the
/// server's DAO, so a test seeds it the way the store is written and reads
/// back what a client wrote. A write here after a client connected reaches it
/// as the server's own change.
///
/// The rules are the shared ones (`planReconcile`, `trustProblem`,
/// `usageSampleWorthKeeping`, the credential stripping); the server's own
/// validation is tested in `server/test/data/`, not here.
class FakeHostRows<T extends Object> {
  FakeHostRows._(
    this._server,
    this._keyOf,
    this._changed,
    this._removed, [
    this._compare,
  ]);

  final FakeDataServer _server;
  final String Function(T row) _keyOf;
  final DataChange Function(T row) _changed;
  final DataChange Function(T row) _removed;
  final int Function(T a, T b)? _compare;
  final _rows = <String, T>{};

  T? getById(String key) => _rows[key];

  /// Every row, in the table's order.
  List<T> getAll() {
    final all = [..._rows.values];
    if (_compare case final compare?) all.sort(compare);
    return all;
  }

  void upsert(T row) => _server._tell(null, [_put(row)]);

  void insert(T row) => upsert(row);

  void delete(String key) {
    final row = _rows[key];
    if (row == null) return;
    _server._tell(null, _removeCascading(row));
  }

  DataChange _put(T row) {
    _rows[_keyOf(row)] = row;
    return _changed(row);
  }

  DataChange _remove(T row) {
    _rows.remove(_keyOf(row));
    return _removed(row);
  }

  /// [row] and what the schema's cascade takes with it: an environment its
  /// installations.
  List<DataChange> _removeCascading(T row) => [
    if (row case final ExecutionEnvironment environment)
      for (final installation in _server.installationRows.getByEnvironment(
        environment.id,
      ))
        _server.installationRows._remove(installation),
    _remove(row),
  ];
}

extension FakeInstallationRows on FakeHostRows<AgentInstallation> {
  List<AgentInstallation> getByEnvironment(String environmentId) => [
    for (final row in getAll())
      if (row.environmentId == environmentId) row,
  ];

  AgentInstallation? getByIdentity(
    String agentId,
    String environmentId,
    String path,
  ) {
    for (final row in getAll()) {
      if (row.agentId == agentId &&
          row.environmentId == environmentId &&
          row.executable.path == path) {
        return row;
      }
    }
    return null;
  }
}

extension FakeKnownHostRows on FakeHostRows<KnownHostKey> {
  KnownHostKey? find(String host, int port) =>
      getById(DataClient.knownHostKey(host, port));

  void trust(KnownHostKey key) => upsert(key);

  void forget(String host, int port) =>
      delete(DataClient.knownHostKey(host, port));
}

/// The usage history of a [FakeDataServer]: kept whole, asked for by range.
class FakeUsageRows {
  FakeUsageRows._(this._server);

  final FakeDataServer _server;
  final _samples = <UsageSample>[];

  void insert(UsageSample sample) {
    _samples
      ..removeWhere(
        (s) =>
            s.accountKey == sample.accountKey &&
            s.windowLabel == sample.windowLabel &&
            s.recordedAt == sample.recordedAt,
      )
      ..add(sample);
    _server._tell(null, [UsageRecorded(sample.accountKey)]);
  }

  UsageSample? latest(String accountKey, String windowLabel) {
    UsageSample? newest;
    for (final s in _samples) {
      if (s.accountKey == accountKey &&
          s.windowLabel == windowLabel &&
          (newest == null || s.recordedAt.isAfter(newest.recordedAt))) {
        newest = s;
      }
    }
    return newest;
  }

  List<UsageSample> since(String accountKey, DateTime since) => [
    for (final s in _samples)
      if (s.accountKey == accountKey && !s.recordedAt.isBefore(since)) s,
  ]..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));

  int count() => _samples.length;
}

extension _FakeHosts on FakeDataServer {
  EnvironmentsSnapshot _environmentsSnapshot() => EnvironmentsSnapshot(
    environments: environmentRows.getAll(),
    sshHosts: sshHostRows.getAll(),
    knownHosts: knownHostRows.getAll(),
  );

  AgentsSnapshot _agentsSnapshot() => AgentsSnapshot(
    installations: installationRows.getAll(),
    claudeAccounts: [
      for (final a in claudeAccountRows.getAll())
        claudeAccountWithoutCredentials(a),
    ],
    codexAccounts: [
      for (final a in codexAccountRows.getAll())
        codexAccountWithoutCredentials(a),
    ],
  );

  AgentInstallation _installation(String id) =>
      installationRows.getById(id) ??
      (throw DataRefused.notFound('no agent installation with id $id'));

  InstallationsReconciled _reconcile(
    InstallationsReconcile r,
    List<DataChange> changes,
  ) {
    final plan = planReconcile(
      environmentId: r.environmentId,
      stored: installationRows.getByEnvironment(r.environmentId),
      found: r.found,
      probed: r.probed,
      readings: r.readings,
      readAt: r.readAt,
    );
    plan.moves.forEach((id, path) {
      changes.add(
        installationRows._put(
          installationAt(_installation(id), path, byUser: false),
        ),
      );
    });
    plan.versions.forEach((id, version) {
      changes.add(
        installationRows._put(
          _installation(id).copyWith(version: version, versionReadAt: r.readAt),
        ),
      );
    });
    for (final row in plan.inserts) {
      changes.add(installationRows._put(row));
    }
    final removed = <AgentInstallation>[];
    final retained = <AgentInstallation>[];
    for (final row in plan.absent) {
      final referenced = sessionRows.getAll().any(
        (session) => session.agentInstallationId == row.id,
      );
      if (referenced) {
        retained.add(row);
      } else {
        changes.add(installationRows._remove(row));
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

  SshHost _putSshHost(SshHost host, List<DataChange> changes) {
    final saved = host.copyWith(
      createdAt: sshHostRows.getById(host.id)?.createdAt,
    );
    changes
      ..add(sshHostRows._put(saved))
      ..add(environmentRows._put(sshEnvironment(saved)));
    return saved;
  }

  DataAck _deleteSshHost(String id, List<DataChange> changes) {
    final host =
        sshHostRows.getById(id) ??
        (throw DataRefused.notFound('no SSH host with id $id'));
    final holding = [
      for (final p in projectRows.getAll())
        if (p.environmentId == host.environmentId) p.name,
    ];
    if (holding.isNotEmpty) {
      throw DataRefused.invalid(
        '${host.name} is still used by ${holding.join(', ')}.',
      );
    }
    if (environmentRows.getById(host.environmentId) case final env?) {
      changes.addAll(environmentRows._removeCascading(env));
    }
    changes.add(sshHostRows._remove(host));
    return const DataAck();
  }

  KnownHostKey _trust(KnownHostKey key, List<DataChange> changes) {
    final trusted = knownHostRows.find(key.host, key.port);
    final refusal = trustProblem(trusted, key);
    if (refusal != null) throw DataRefused.invalid(refusal);
    if (trusted != null) return trusted;
    final stamped = KnownHostKey(
      host: key.host,
      port: key.port,
      keyType: key.keyType,
      fingerprint: key.fingerprint,
      trustedAt: _now(),
    );
    changes.add(knownHostRows._put(stamped));
    return stamped;
  }

  ClaudeAccount _saveClaude(ClaudeAccount account, List<DataChange> changes) {
    ClaudeAccount? existing;
    for (final a in claudeAccountRows.getAll()) {
      if (a.email == account.email &&
          a.organizationUuid == account.organizationUuid) {
        existing = a;
      }
    }
    final saved = existing == null
        ? account
        : account.copyWith(id: existing.id);
    claudeAccountRows._rows[saved.id] = saved;
    final stripped = claudeAccountWithoutCredentials(saved);
    changes.add(ClaudeAccountChanged(stripped));
    return stripped;
  }

  CodexAccount _saveCodex(CodexAccount account, List<DataChange> changes) {
    CodexAccount? existing;
    for (final a in codexAccountRows.getAll()) {
      if (a.accountId == account.accountId) existing = a;
    }
    final saved = existing == null
        ? account
        : account.copyWith(id: existing.id);
    codexAccountRows._rows[saved.id] = saved;
    final stripped = codexAccountWithoutCredentials(saved);
    changes.add(CodexAccountChanged(stripped));
    return stripped;
  }

  int _recordUsage(List<UsageSample> samples, List<DataChange> changes) {
    var written = 0;
    final gained = <String>{};
    for (final sample in samples) {
      if (!usageSampleWorthKeeping(
        sample,
        usageRows.latest(sample.accountKey, sample.windowLabel),
      )) {
        continue;
      }
      usageRows._samples.add(sample);
      gained.add(sample.accountKey);
      written++;
    }
    changes.addAll(gained.map(UsageRecorded.new));
    return written;
  }

  Object? _handleHosts(DataRequest<Object?> request, List<DataChange> c) =>
      switch (request) {
        EnvironmentsList() => _environmentsSnapshot(),
        EnvironmentPut(:final environment) => () {
          final kept = environment.copyWith(
            createdAt: environmentRows.getById(environment.id)?.createdAt,
          );
          c.add(environmentRows._put(kept));
          return kept;
        }(),
        SshHostPut(:final host) => _putSshHost(host, c),
        SshHostDelete(:final id) => _deleteSshHost(id, c),
        KnownHostTrust(:final key) => _trust(key, c),
        KnownHostForget(:final host, :final port) => () {
          if (knownHostRows.find(host, port) case final key?) {
            c.add(knownHostRows._remove(key));
          }
          return const DataAck();
        }(),
        AgentsList() => _agentsSnapshot(),
        final InstallationsReconcile r => _reconcile(r, c),
        final InstallationVersion r => () {
          final row = _installation(
            r.id,
          ).copyWith(version: r.version, versionReadAt: r.readAt);
          c.add(installationRows._put(row));
          return row;
        }(),
        final InstallationSetPath r => () {
          final row = _installation(r.id);
          final path = r.path.trim();
          if (path.isEmpty ||
              installationPathTaken(installationRows.getAll(), row, path)) {
            throw DataRefused.invalid('$path is taken');
          }
          final moved = installationAt(row, path, byUser: true);
          c.add(installationRows._put(moved));
          return moved;
        }(),
        ClaudeAccountSave(:final account) => _saveClaude(account, c),
        ClaudeAccountCredentials(:final id) =>
          claudeAccountRows.getById(id) ??
              (throw DataRefused.notFound('no saved Claude account $id')),
        ClaudeAccountDelete(:final id) => () {
          if (claudeAccountRows._rows.remove(id) != null) {
            c.add(ClaudeAccountRemoved(id));
          }
          return const DataAck();
        }(),
        CodexAccountSave(:final account) => _saveCodex(account, c),
        CodexAccountCredentials(:final id) =>
          codexAccountRows.getById(id) ??
              (throw DataRefused.notFound('no saved Codex account $id')),
        CodexAccountDelete(:final id) => () {
          if (codexAccountRows._rows.remove(id) != null) {
            c.add(CodexAccountRemoved(id));
          }
          return const DataAck();
        }(),
        UsageRecord(:final samples) => _recordUsage(samples, c),
        UsageHistory(:final accountKey, :final since) => usageRows.since(
          accountKey,
          since,
        ),
        _ => throw StateError('not a hosts request: ${request.kind}'),
      };
}
