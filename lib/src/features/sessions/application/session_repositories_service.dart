import '../../repositories/data/repository_dao.dart';
import '../../repositories/domain/repository.dart';
import '../data/session_dao.dart';
import '../data/session_repository_dao.dart';

/// Raised when a repository cannot be attached to a session.
class SessionRepositoryException implements Exception {
  SessionRepositoryException(this.message);
  final String message;
  @override
  String toString() => 'SessionRepositoryException: $message';
}

/// Manages the set of repositories associated with a session, enforcing that all
/// repositories belong to the **same project** (a session spans repositories
/// within one project — Loop 13).
class SessionRepositoriesService {
  SessionRepositoriesService({
    required this.sessionDao,
    required this.repositoryDao,
    required this.linkDao,
  });

  final SessionDao sessionDao;
  final RepositoryDao repositoryDao;
  final SessionRepositoryDao linkDao;

  /// The repositories linked to [sessionId], primary first.
  List<Repository> forSession(String sessionId) {
    return linkDao
        .linksFor(sessionId)
        .map((link) => repositoryDao.getById(link.repositoryId))
        .whereType<Repository>()
        .toList();
  }

  /// Attaches [repositoryId] to [sessionId]. Throws if the repository is in a
  /// different project than the session's primary repository.
  void attach(String sessionId, String repositoryId) {
    final session = sessionDao.getById(sessionId);
    if (session == null) {
      throw SessionRepositoryException('Unknown session: $sessionId');
    }
    final primary = repositoryDao.getById(session.repositoryId);
    final candidate = repositoryDao.getById(repositoryId);
    if (primary == null || candidate == null) {
      throw SessionRepositoryException('Unknown repository: $repositoryId');
    }
    if (candidate.projectId != primary.projectId) {
      throw SessionRepositoryException(
        'A session can only span repositories within the same project.',
      );
    }
    linkDao.link(sessionId, repositoryId);
  }

  /// Detaches a non-primary repository from a session.
  void detach(String sessionId, String repositoryId) =>
      linkDao.unlink(sessionId, repositoryId);
}
