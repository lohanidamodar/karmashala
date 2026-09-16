import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import 'package:karmashala_git/repositories.dart';

/// Data-access for [Repository] rows. Hand-written SQL, no codegen.
class RepositoryDao {
  RepositoryDao(this._db);

  final AppDatabase _db;

  void insert(Repository repository) {
    _db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at, canonical_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        repository.id,
        repository.projectId,
        repository.name,
        repository.path.environmentId,
        repository.path.path,
        isoFromDate(repository.createdAt),
        repository.canonicalId,
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

  /// Records what repository the row [id] is a checkout of, or clears it. Its own
  /// statement, so a rescan that never read `origin` cannot undo it.
  void updateCanonicalId(String id, String? canonicalId) {
    _db.execute('UPDATE repositories SET canonical_id = ? WHERE id = ?;', [
      canonicalId,
      id,
    ]);
  }

  /// Every row whose working tree is [path]. Filtered in Dart after an indexed
  /// read: case and separator folding are decisions SQL cannot make.
  List<Repository> getByLocation(EnvironmentPath path) {
    final rows = _db.query(
      'SELECT * FROM repositories WHERE environment_id = ?;',
      [path.environmentId],
    );
    return [
      for (final row in rows.map(_fromRow))
        if (samePath(row.path.path, path.path)) row,
    ];
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

  /// How many rows of recorded history a [delete] would destroy — every one of
  /// those foreign keys cascades, so this is the size of the hole, not advice.
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
    canonicalId: row['canonical_id'] as String?,
  );
}
