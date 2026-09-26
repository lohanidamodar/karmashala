import 'package:karmashala_store/database.dart';

/// What the notes and todos handlers ask of the workspace tables to file a
/// row: read-only, and the only place they read beyond their own tables.
class FilingLookup {
  FilingLookup(this._db);

  final AppDatabase _db;

  bool projectExists(String projectId) =>
      _db.query('SELECT 1 FROM projects WHERE id = ?;', [projectId]).isNotEmpty;

  String? repositoryOfSession(String sessionId) => _first(
    'SELECT repository_id AS v FROM sessions WHERE id = ?;',
    sessionId,
  );

  String? projectOfRepository(String repositoryId) => _first(
    'SELECT project_id AS v FROM repositories WHERE id = ?;',
    repositoryId,
  );

  String? projectOfSession(String sessionId) {
    final repository = repositoryOfSession(sessionId);
    return repository == null ? null : projectOfRepository(repository);
  }

  String? _first(String sql, String id) {
    final rows = _db.query(sql, [id]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }
}
