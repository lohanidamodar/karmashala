import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../domain/repository.dart';

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

  /// Records what repository the row [id] is a checkout of, or clears it.
  ///
  /// Its own statement rather than a field of [update], which is the rescan's
  /// write and knows only about names and paths. This one is written from a
  /// reading of `origin` and must not be undone by a sweep that never looked at
  /// one — the same separation `AgentInstallationDao.updatePath` keeps for the
  /// same reason.
  void updateCanonicalId(String id, String? canonicalId) {
    _db.execute('UPDATE repositories SET canonical_id = ? WHERE id = ?;', [
      canonicalId,
      id,
    ]);
  }

  /// Every row whose working tree is [path], compared the way the filesystem
  /// does rather than the way a string does.
  ///
  /// Plural because it can be: the table has no uniqueness on a location, and
  /// two rows recorded from two spellings of one directory are exactly what
  /// [samePath] exists to reconcile. Filtered in Dart after an indexed read of
  /// the environment, because case folding and separator folding are decisions
  /// SQL cannot make — `/home/A` and `/home/a` are two directories on POSIX and
  /// one on Windows.
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
    canonicalId: row['canonical_id'] as String?,
  );
}
