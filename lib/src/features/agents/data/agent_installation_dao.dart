import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/discovery.dart';

/// Data-access for [AgentInstallation] rows. Hand-written SQL, no codegen.
///
/// The underlying table has a `UNIQUE(agent_kind, environment_id,
/// executable_path)` constraint, enforcing that each `(agent, environment,
/// executable)` is one independent installation. `agent_kind` has always been a
/// `TEXT` column holding the agent's descriptor id, so it is read straight
/// through as [AgentInstallation.agentId] — an unrecognised agent loads rather
/// than throwing.
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
  /// asked**.
  ///
  /// An upgraded CLI is the same installation, so it keeps its row and its id —
  /// which matters because the id is what settings pin as the default agent.
  /// Deleting and re-inserting would silently unpick that choice.
  ///
  /// [readAt] is written on every reading, including one that matches what is
  /// already stored. That is the whole point: the old `updateVersion` wrote
  /// only when the *number* changed, so a re-read that confirmed the number
  /// left it looking exactly as old as before. A confirmed reading is a fresh
  /// reading.
  ///
  /// A null [version] is refused rather than written. Discovery can locate a
  /// binary and fail to run `--version`, and storing that as "no version" would
  /// erase a number we did know for an answer we never got — an unknown
  /// presenting itself as a reading of zero (CLAUDE.md §19). The caller keeps
  /// the previous number *and* its previous timestamp, because nothing was
  /// learned.
  void recordVersion(String id, String? version, {required DateTime readAt}) {
    if (version == null) return;
    _db.execute(
      'UPDATE agent_installations SET version = ?, version_read_at = ? '
      'WHERE id = ?;',
      [version, isoFromDate(readAt), id],
    );
  }

  /// Moves an installation to [path], keeping its row and its id.
  ///
  /// The same reasoning as [recordVersion], for the same reason: the id is what
  /// settings pin as the default agent and what every session row references,
  /// so an executable that moved must not become a new installation. That is
  /// what made the junction failure worse than it had to be — the repair had no
  /// way to say "the same Codex, at a different path".
  ///
  /// [byUser] records who chose it, so a later sweep knows whether it may pick
  /// a different path. Returns `false` when [path] is already taken in this
  /// environment by another row for the same agent — the table's
  /// `UNIQUE (agent_kind, environment_id, executable_path)` — because merging
  /// two rows is a decision for the caller that can see both, not for a setter.
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
  /// A session's installation is a record of *which agent ran it*, and an agent
  /// that moved on disk — reinstalled elsewhere, or found at its durable path
  /// after having first been seen through a wrapper — is the same agent. Left
  /// alone, those sessions point at a row that is about to go, which is both
  /// unresumable and undeletable: `sessions.agent_installation_id` is
  /// `ON DELETE RESTRICT`.
  void repointSessions({required String from, required String to}) {
    _db.execute(
      'UPDATE sessions SET agent_installation_id = ? '
      'WHERE agent_installation_id = ?;',
      [to, from],
    );
  }

  /// Deletes [id] unless something still points at it, and says whether it
  /// went.
  ///
  /// Asking first rather than deleting and catching: `sessions` references this
  /// table `ON DELETE RESTRICT`, so removing a row that ran even one session
  /// raises `SqliteException(1811)` — and that exception, thrown from the
  /// middle of a re-detection sweep, used to abort the whole run and leave the
  /// app reporting *no agents at all* because one uninstalled CLI could not be
  /// tidied away. A row somebody's history depends on is kept, not forced.
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
      // Some other table references it. Same rule: the row stays, and the
      // sweep carries on rather than the app losing sight of every agent.
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
