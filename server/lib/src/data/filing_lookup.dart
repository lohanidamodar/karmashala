import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

/// What the notes and todos handlers ask of the workspace tables to file a
/// row: read-only, through the workspace domain's own DAOs, and the only
/// place they read beyond their own tables.
class FilingLookup {
  FilingLookup(this._db)
    : _projects = ProjectDao(_db),
      _repositories = RepositoryDao(_db);

  final AppDatabase _db;
  final ProjectDao _projects;
  final RepositoryDao _repositories;

  bool projectExists(String projectId) => _projects.getById(projectId) != null;

  /// A session's repository — the sessions domain, not yet the server's own
  /// data API (slice 1c), so read here as it stands.
  String? repositoryOfSession(String sessionId) {
    final rows = _db.query(
      'SELECT repository_id AS v FROM sessions WHERE id = ?;',
      [sessionId],
    );
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  String? projectOfRepository(String repositoryId) =>
      _repositories.getById(repositoryId)?.projectId;

  String? projectOfSession(String sessionId) {
    final repository = repositoryOfSession(sessionId);
    return repository == null ? null : projectOfRepository(repository);
  }
}
