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

  /// The same list, with **where each one is actually worked in** and whether
  /// that directory belongs to this session alone.
  ///
  /// ## Why a secondary repository is not worktreed, and why that is said out
  /// loud rather than fixed
  ///
  /// `SessionLauncher` creates a worktree for the session's primary repository
  /// and for nothing else, so two concurrent worktree sessions on a multi-repo
  /// project are isolated in the primary and share every other checkout — one
  /// working tree, one index, one branch between them. Fan-out always uses
  /// worktrees, so it would meet this first.
  ///
  /// Worktreeing every repository was considered and rejected on four counts,
  /// each checkable:
  ///
  /// 1. **Nothing populates the field at launch.** `SessionLaunchRequest
  ///    .additionalRepositories` has no producer anywhere in `lib/` — not
  ///    fan-out, not the new-session dialog, not MCP. The only way a session
  ///    gains a second repository is [attach], from `SessionRepositoriesBar`,
  ///    *after* the launch. A worktree created in the launcher would therefore
  ///    be unreachable code.
  /// 2. **The lifecycle is single-worktree all the way down.**
  ///    `Session.worktree` is one column; `SessionArchiveService` removes that
  ///    one directory; `SessionDelivery` reports one branch and one upstream;
  ///    the MCP `worktree_remove` rule is written per checkout; the changes view
  ///    draws one. N worktrees per session is a schema change plus new
  ///    semantics for archive, delivery and removal.
  /// 3. **Nobody would be standing in them.** The agent's process has one
  ///    working directory — the primary checkout — and nothing tells it where a
  ///    secondary worktree would be. It would be N directories created, paid
  ///    for and cleaned up, that no agent is ever put into.
  /// 4. **A secondary repository is frequently only read.** This workspace's
  ///    own shape is a hub project with sibling repositories; a session working
  ///    in one and consulting another is the ordinary case, and consulting does
  ///    not collide.
  ///
  /// What is real is the *silence*. `list_checkouts` hands an agent every
  /// checkout path in the project, `terminal_open` takes any working directory,
  /// and until now nothing anywhere noticed that two sessions were in the same
  /// one. So the sharing stays and stops being invisible: this is what the chip
  /// bar's tooltip and the `list_checkouts` tool both read.
  ///
  /// The primary checkout is included and answered by the same rule — a session
  /// that runs *in the repository* rather than in a worktree of it shares that
  /// checkout with every other session that does, which is the same collision
  /// wearing the primary's hat and was never named either.
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
    // Only the primary can be anywhere but its repository root: the launcher's
    // worktree and `Session.workingDirectory` are both about the repository the
    // session was launched against. An additional link carries no directory of
    // its own, so the checkout is the repository — which is the whole finding.
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
