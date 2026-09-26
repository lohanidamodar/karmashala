import 'dart:io';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_store/database.dart';

/// The two tables the server writes about its agents: this machine's
/// `execution_environments` row, and one `agent_installations` row per CLI it
/// found. Narrow on purpose, like `CheckoutRows`: the app's DAOs carry every
/// query its settings need; the host needs "is it recorded" and "record it".
///
/// It keeps the desktop's rules for the rows it shares with the app: a path a
/// person chose is never overruled, a CLI that moved keeps its row (and its
/// id, which settings pin), and rows are never deleted here — a session row
/// points at its installation (`ON DELETE RESTRICT`), and a CLI that has gone
/// is the app's to reconcile with the person.
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

  /// Records [found]: the version it answered now on the row already at its
  /// agent, environment and path (the table's identity). With none there:
  /// nothing when a person pinned the same agent here to another path that
  /// still opens — their answer; the row moved in place when the same agent's
  /// row here points at a path that is gone; else a new row. Returns the row
  /// as recorded, and whether it is new; null when a pinned row stands.
  ({AgentInstallation installation, bool added})? record(
    AgentInstallation found,
  ) {
    final existing = _byIdentity(
      found.agentId,
      found.executable.environmentId,
      found.executable.path,
    );
    if (existing == null) {
      final elsewhere = [
        for (final row in inEnvironment(found.executable.environmentId))
          if (row.agentId == found.agentId) row,
      ];
      for (final row in elsewhere) {
        if (row.executableByUser && _opens(row.executable.path)) return null;
      }
      for (final row in elsewhere) {
        if (row.executableByUser || _opens(row.executable.path)) continue;
        _db.execute(
          'UPDATE agent_installations SET executable_path = ?, version = ?, '
          'version_read_at = ? WHERE id = ?;',
          [
            found.executable.path,
            found.version ?? row.version,
            found.versionReadAt == null
                ? (row.versionReadAt == null
                      ? null
                      : isoFromDate(row.versionReadAt!))
                : isoFromDate(found.versionReadAt!),
            row.id,
          ],
        );
        return (installation: _byId(row.id) ?? row, added: false);
      }
      // OR IGNORE: the desktop's own sweep may record the same CLI a moment
      // before — the identity is unique — and then that row is the one.
      _db.execute(
        'INSERT OR IGNORE INTO agent_installations '
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
      final recorded = _byIdentity(
        found.agentId,
        found.executable.environmentId,
        found.executable.path,
      );
      if (recorded != null && recorded.id != found.id) {
        return (installation: recorded, added: false);
      }
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

  /// Whether [path] is a file on this machine — where every row this writes
  /// is recorded.
  static bool _opens(String path) => File(path).existsSync();

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
