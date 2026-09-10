import '../../explorer/application/checkout.dart';
import '../../repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import '../data/session_dao.dart';
import '../data/session_repository_dao.dart';
import '../domain/session.dart';
import '../domain/session_checkouts.dart';

/// Raised when a repository cannot be attached to a session.
class SessionRepositoryException implements Exception {
  SessionRepositoryException(this.message);
  final String message;
  @override
  String toString() => 'SessionRepositoryException: $message';
}

/// Manages the set of repositories on a session, enforcing that they all belong
/// to the **same project**.
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

  /// The same list, with **where each one is actually worked in** and whether
  /// that directory is this session's alone. Only the primary is worktreed.
  List<SessionCheckout> checkoutsFor(String sessionId) {
    final session = sessionDao.getById(sessionId);
    if (session == null) return const [];
    final others = sessionDao.getAll();
    return [
      for (final link in linkDao.linksFor(sessionId))
        if (repositoryDao.getById(link.repositoryId) case final repository?)
          _checkoutFor(session, link, repository, others),
    ];
  }

  SessionCheckout _checkoutFor(
    Session session,
    SessionRepositoryLink link,
    Repository repository,
    List<Session> others,
  ) {
    // Only the primary can be anywhere but its repository root: an additional
    // link carries no directory of its own, which is the whole finding.
    final worktree = link.isPrimary ? session.worktree : null;
    final directory = link.isPrimary
        ? (session.workingDirectory ?? session.worktree ?? repository.path)
        : repository.path;
    final isolated =
        worktree != null &&
        worktree.environmentId == directory.environmentId &&
        samePath(worktree.path, directory.path);
    return SessionCheckout(
      repositoryId: repository.id,
      name: repository.name,
      directory: directory,
      isPrimary: link.isPrimary,
      isolation: isolated
          ? CheckoutIsolation.isolated
          : CheckoutIsolation.shared,
      sharedWith: isolated
          ? const []
          : sessionsWorkingIn(directory, excluding: session.id, among: others),
    );
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
