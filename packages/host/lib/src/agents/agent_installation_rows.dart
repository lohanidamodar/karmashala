import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_store/database.dart';

/// The two tables a standalone server writes about its agents: this machine's
/// `execution_environments` row, and one `agent_installations` row per CLI it
/// found. Narrow on purpose, like `CheckoutRows`: the app's DAOs carry every
/// query its settings need; the host needs "is it recorded" and "record it".
///
/// Rows are never deleted here: a session row points at its installation
/// (`ON DELETE RESTRICT`), and a CLI that has gone is the app's to reconcile
/// with the person.
class AgentInstallationRows {
  AgentInstallationRows(this._db);

  final AppDatabase _db;

  /// Records [environment] unless a row with its id is already there — the
  /// app's own row for this machine is kept as the app wrote it.
  void ensureEnvironment(ExecutionEnvironment environment) {
    _db.execute(
      'INSERT OR IGNORE INTO execution_environments '
      '(id, kind, name, wsl_distribution, ssh_host_id, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        environment.id,
        environment.kind.name,
        environment.name,
        environment.wslDistribution,
        environment.sshHostId,
        isoFromDate(environment.createdAt),
      ],
    );
  }

  /// Records [found]: a new row when no row has its agent, environment and
  /// path (the table's identity), else the version it answered now on the
  /// row already there. Returns the row as recorded, and whether it is new.
  ({AgentInstallation installation, bool added}) record(
    AgentInstallation found,
  ) {
    final existing = _byIdentity(
      found.agentId,
      found.executable.environmentId,
      found.executable.path,
    );
    if (existing == null) {
      _db.execute(
        'INSERT INTO agent_installations '
        '(id, agent_kind, environment_id, executable_path, version, '
        'version_read_at, created_at, executable_by_user) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, 0);',
        [
          found.id,
          found.agentId,
          found.executable.environmentId,
          found.executable.path,
          found.version,
          found.versionReadAt == null
              ? null
              : isoFromDate(found.versionReadAt!),
          isoFromDate(found.createdAt),
        ],
      );
      return (installation: found, added: true);
    }
    final version = found.version;
    final readAt = found.versionReadAt;
    if (version != null && readAt != null) {
      _db.execute(
        'UPDATE agent_installations SET version = ?, version_read_at = ? '
        'WHERE id = ?;',
        [version, isoFromDate(readAt), existing.id],
      );
    }
    return (installation: _byId(existing.id) ?? existing, added: false);
  }

  /// Every installation recorded for [environmentId], oldest first.
  List<AgentInstallation> inEnvironment(String environmentId) => [
    for (final row in _db.query(
      'SELECT * FROM agent_installations WHERE environment_id = ? '
      'ORDER BY created_at, id;',
      [environmentId],
    ))
      _fromRow(row),
  ];

  AgentInstallation? _byIdentity(
    String agentId,
    String environmentId,
    String path,
  ) {
    final rows = _db.query(
      'SELECT * FROM agent_installations WHERE agent_kind = ? '
      'AND environment_id = ? AND executable_path = ?;',
      [agentId, environmentId, path],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  AgentInstallation? _byId(String id) {
    final rows = _db.query('SELECT * FROM agent_installations WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static AgentInstallation _fromRow(Map<String, Object?> row) =>
      AgentInstallation(
        id: row['id']! as String,
        agentId: row['agent_kind']! as String,
        executable: EnvironmentPath(
          environmentId: row['environment_id']! as String,
          path: row['executable_path']! as String,
        ),
        version: row['version'] as String?,
        versionReadAt: row['version_read_at'] == null
            ? null
            : dateFromIso(row['version_read_at']),
        createdAt: dateFromIso(row['created_at']),
        executableByUser: boolFromInt(row['executable_by_user'] ?? 0),
      );
}
