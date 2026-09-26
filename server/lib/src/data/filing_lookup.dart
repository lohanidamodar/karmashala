import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_session_engine/store.dart';

/// What the notes and todos handlers ask of the workspace and sessions tables
/// to file a row: read-only, through those domains' own DAOs, and the only
/// place they read beyond their own tables.
class FilingLookup {
  FilingLookup(AppDatabase db)
    : _projects = ProjectDao(db),
      _repositories = RepositoryDao(db),
      _sessions = SessionDao(db);

  final ProjectDao _projects;
  final SessionDao _sessions;
  final RepositoryDao _repositories;

  bool projectExists(String projectId) => _projects.getById(projectId) != null;

  /// A session's repository, through the sessions domain's own DAO.
  String? repositoryOfSession(String sessionId) =>
      _sessions.getById(sessionId)?.repositoryId;

  String? projectOfRepository(String repositoryId) =>
      _repositories.getById(repositoryId)?.projectId;

  String? projectOfSession(String sessionId) {
    final repository = repositoryOfSession(sessionId);
    return repository == null ? null : projectOfRepository(repository);
  }
}
