import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/discovery.dart';

/// Data-access for [AgentInstallation] rows. Hand-written SQL, no codegen.
///
/// `UNIQUE(agent_kind, environment_id, executable_path)` is what makes each
/// `(agent, environment, executable)` one independent installation.
/// `agent_kind` is read straight through as [AgentInstallation.agentId], so an
/// unrecognised agent loads rather than throwing.
class AgentInstallationDao {
  AgentInstallationDao(this._db);

  final AppDatabase _db;

  void insert(AgentInstallation installation) {
    _db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, version, '
      'version_read_at, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
      [
        installation.id,
        installation.agentId,
        installation.executable.environmentId,
        installation.executable.path,
        installation.version,
        installation.versionReadAt == null
            ? null
            : isoFromDate(installation.versionReadAt!),
        isoFromDate(installation.createdAt),
        intFromBool(installation.executableByUser),
      ],
    );
  }

  AgentInstallation? getById(String id) {
    final rows = _db.query('SELECT * FROM agent_installations WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Finds an installation by its natural identity — `(agentId, environmentId,
  /// executablePath)` — which the table enforces as unique.
  AgentInstallation? getByIdentity(
    String agentId,
    String environmentId,
    String executablePath,
  ) {
    final rows = _db.query(
      'SELECT * FROM agent_installations WHERE agent_kind = ? '
      'AND environment_id = ? AND executable_path = ?;',
      [agentId, environmentId, executablePath],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<AgentInstallation> getAll() {
    final rows = _db.query(
      'SELECT * FROM agent_installations ORDER BY created_at, id;',
    );
    return rows.map(_fromRow).toList();
  }

  /// Installations available in a given environment.
  List<AgentInstallation> getByEnvironment(String environmentId) {
    final rows = _db.query(
      'SELECT * FROM agent_installations WHERE environment_id = ? '
      'ORDER BY created_at, id;',
      [environmentId],
    );
    return rows.map(_fromRow).toList();
  }

  /// Records what the CLI at this installation answered, and **when it was
  /// asked**. An upgraded CLI keeps its row and its id, which is what settings
  /// pin as the default agent.
  ///
  /// [readAt] is written on every reading, including one that confirms the
  /// stored number: a confirmed reading is a fresh reading, and the old
  /// `updateVersion` left it looking as old as before. A null [version] is
  /// refused rather than written — discovery can locate a binary and fail to run
  /// `--version`, and storing that as "no version" would erase a number we knew
  /// for an answer we never got.
  void recordVersion(String id, String? version, {required DateTime readAt}) {
    if (version == null) return;
    _db.execute(
      'UPDATE agent_installations SET version = ?, version_read_at = ? '
      'WHERE id = ?;',
      [version, isoFromDate(readAt), id],
    );
  }

  /// Moves an installation to [path], keeping its row and its id: the id is what
  /// settings pin as the default agent and what every session row references, so
  /// an executable that moved must not become a new installation.
  ///
  /// [byUser] records who chose it, so a later sweep knows whether it may pick a
  /// different path. Returns `false` when [path] is already taken in this
  /// environment by another row for the same agent, because merging two rows is
  /// a decision for the caller that can see both.
  bool updatePath(String id, String path, {required bool byUser}) {
    try {
      _db.execute(
        'UPDATE agent_installations SET executable_path = ?, '
        'executable_by_user = ? WHERE id = ?;',
        [path, intFromBool(byUser), id],
      );
      return true;
    } on SqliteException {
      return false;
    }
  }

  void delete(String id) {
    _db.execute('DELETE FROM agent_installations WHERE id = ?;', [id]);
  }

  /// Moves every session recorded against installation [from] onto [to].
  ///
  /// An agent that moved on disk is the same agent. Left alone, its sessions
  /// point at a row that is about to go, which is both unresumable and
  /// undeletable: `sessions.agent_installation_id` is `ON DELETE RESTRICT`.
  void repointSessions({required String from, required String to}) {
    _db.execute(
      'UPDATE sessions SET agent_installation_id = ? '
      'WHERE agent_installation_id = ?;',
      [to, from],
    );
  }

  /// Deletes [id] unless something still points at it, and says whether it went.
  ///
  /// Asked first rather than deleted and caught: `sessions` references this table
  /// `ON DELETE RESTRICT`, and that `SqliteException(1811)` thrown from the
  /// middle of a re-detection sweep used to abort the whole run, leaving the app
  /// reporting *no agents at all* because one uninstalled CLI could not be
  /// tidied away.
  bool deleteIfUnreferenced(String id) {
    final referencing = _db.query(
      'SELECT 1 FROM sessions WHERE agent_installation_id = ? LIMIT 1;',
      [id],
    );
    if (referencing.isNotEmpty) return false;
    try {
      delete(id);
      return true;
    } on SqliteException {
      // Some other table references it. Same rule: the row stays and the sweep
      // carries on.
      return false;
    }
  }

  AgentInstallation _fromRow(Map<String, Object?> row) => AgentInstallation(
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
