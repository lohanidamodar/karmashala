import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/session.dart';
import '../domain/session_status.dart';

/// Data-access for [Session] rows. Hand-written SQL, no codegen.
class SessionDao {
  SessionDao(this._db);

  final AppDatabase _db;

  void insert(Session session) {
    _db.execute(
      'INSERT INTO sessions '
      '(id, repository_id, agent_installation_id, title, use_worktree, '
      'worktree_environment_id, worktree_path, status, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        session.id,
        session.repositoryId,
        session.agentInstallationId,
        session.title,
        intFromBool(session.useWorktree),
        session.worktree?.environmentId,
        session.worktree?.path,
        session.status.name,
        isoFromDate(session.createdAt),
      ],
    );
  }

  /// Updates the mutable fields of a session (title, worktree, status).
  void update(Session session) {
    _db.execute(
      'UPDATE sessions SET title = ?, use_worktree = ?, '
      'worktree_environment_id = ?, worktree_path = ?, status = ? '
      'WHERE id = ?;',
      [
        session.title,
        intFromBool(session.useWorktree),
        session.worktree?.environmentId,
        session.worktree?.path,
        session.status.name,
        session.id,
      ],
    );
  }

  /// Updates only the [status] of session [id].
  void updateStatus(String id, SessionStatus status) {
    _db.execute('UPDATE sessions SET status = ? WHERE id = ?;', [
      status.name,
      id,
    ]);
  }

  Session? getById(String id) {
    final rows = _db.query('SELECT * FROM sessions WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<Session> getAll() {
    final rows = _db.query('SELECT * FROM sessions ORDER BY created_at, id;');
    return rows.map(_fromRow).toList();
  }

  /// Sessions targeting [repositoryId].
  List<Session> getByRepository(String repositoryId) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE repository_id = ? ORDER BY created_at, id;',
      [repositoryId],
    );
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM sessions WHERE id = ?;', [id]);
  }

  Session _fromRow(Map<String, Object?> row) {
    final worktreeEnv = row['worktree_environment_id'] as String?;
    final worktreePath = row['worktree_path'] as String?;
    return Session(
      id: row['id']! as String,
      repositoryId: row['repository_id']! as String,
      agentInstallationId: row['agent_installation_id']! as String,
      title: row['title']! as String,
      useWorktree: boolFromInt(row['use_worktree']),
      worktree: (worktreeEnv != null && worktreePath != null)
          ? EnvironmentPath(environmentId: worktreeEnv, path: worktreePath)
          : null,
      status: SessionStatus.values.byName(row['status']! as String),
      createdAt: dateFromIso(row['created_at']),
    );
  }
}
