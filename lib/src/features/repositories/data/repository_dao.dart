import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/repository.dart';

/// Data-access for [Repository] rows. Hand-written SQL, no codegen.
class RepositoryDao {
  RepositoryDao(this._db);

  final AppDatabase _db;

  void insert(Repository repository) {
    _db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        repository.id,
        repository.projectId,
        repository.name,
        repository.path.environmentId,
        repository.path.path,
        isoFromDate(repository.createdAt),
      ],
    );
  }

  void update(Repository repository) {
    _db.execute(
      'UPDATE repositories SET name = ?, environment_id = ?, path = ? '
      'WHERE id = ?;',
      [
        repository.name,
        repository.path.environmentId,
        repository.path.path,
        repository.id,
      ],
    );
  }

  Repository? getById(String id) {
    final rows = _db.query('SELECT * FROM repositories WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<Repository> getAll() {
    final rows = _db.query(
      'SELECT * FROM repositories ORDER BY created_at, id;',
    );
    return rows.map(_fromRow).toList();
  }

  /// Repositories belonging to [projectId].
  List<Repository> getByProject(String projectId) {
    final rows = _db.query(
      'SELECT * FROM repositories WHERE project_id = ? '
      'ORDER BY created_at, id;',
      [projectId],
    );
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM repositories WHERE id = ?;', [id]);
  }

  /// How many rows of recorded history a [delete] of [repositoryId] would
  /// destroy: native sessions, the extra links of sessions whose *primary*
  /// repository is elsewhere, imported CLI history, and fanout comparisons.
  ///
  /// Every one of those foreign keys is `ON DELETE CASCADE`, so this number is
  /// not advisory — it is the size of the hole [delete] would leave. It exists
  /// because a rescan may now retire a checkout whose folder has gone, and a
  /// folder going away is no reason at all to lose the transcript of the work
  /// that was done in it. `fanout_comparisons` is counted with the rest
  /// deliberately: those rows are written to stay readable *after* the worktree
  /// they describe is removed, which is exactly this situation.
  ///
  /// `UNION` rather than four sums, because a session's primary link appears in
  /// both `sessions` and `session_repositories` and counting it twice would
  /// overstate what is at stake.
  int historyReferenceCount(String repositoryId) {
    final rows = _db.query(
      'SELECT COUNT(*) AS n FROM ('
      'SELECT id FROM sessions WHERE repository_id = ? '
      'UNION SELECT session_id FROM session_repositories WHERE repository_id = ? '
      'UNION SELECT id FROM imported_sessions WHERE repository_id = ? '
      'UNION SELECT id FROM fanout_comparisons WHERE repository_id = ?'
      ');',
      [repositoryId, repositoryId, repositoryId, repositoryId],
    );
    return rows.first['n']! as int;
  }

  Repository _fromRow(Map<String, Object?> row) => Repository(
    id: row['id']! as String,
    projectId: row['project_id']! as String,
    name: row['name']! as String,
    path: EnvironmentPath(
      environmentId: row['environment_id']! as String,
      path: row['path']! as String,
    ),
    createdAt: dateFromIso(row['created_at']),
  );
}
