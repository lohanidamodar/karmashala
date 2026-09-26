import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/session.dart';

import '../../workspaces/data/workspace_data.dart';
import '../data/sessions_data.dart';

/// Raised when a repository cannot be attached to a session — the server's
/// refusal, in its words.
class SessionRepositoryException implements Exception {
  SessionRepositoryException(this.message);
  final String message;
  @override
  String toString() => 'SessionRepositoryException: $message';
}

/// The set of repositories on a session: read from the copy, changed through
/// the server — which alone enforces that they all belong to the **same
/// project**.
class SessionRepositoriesService {
  SessionRepositoriesService({required this.sessions, required this.workspace});

  final SessionsData sessions;
  final WorkspaceData workspace;

  /// The repositories linked to [sessionId], primary first.
  List<Repository> forSession(String sessionId) => sessions
      .linksFor(sessionId)
      .map((link) => workspace.repository(link.repositoryId))
      .whereType<Repository>()
      .toList();

  /// The same list, with **where each one is actually worked in** and whether
  /// that directory is this session's alone. Only the primary is worktreed.
  List<SessionCheckout> checkoutsFor(String sessionId) {
    final session = sessions.getById(sessionId);
    if (session == null) return const [];
    final others = sessions.getAll();
    return [
      for (final link in sessions.linksFor(sessionId))
        if (workspace.repository(link.repositoryId) case final repository?)
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
          : sessionsWorkingIn(
              directory,
              excluding: session.id,
              among: others,
              pathsMatch: samePath,
            ),
    );
  }

  /// Attaches [repositoryId] to [sessionId]. Throws
  /// [SessionRepositoryException] with the server's words when it refuses —
  /// a repository of another project, or one it does not know.
  Future<void> attach(String sessionId, String repositoryId) async {
    try {
      await sessions.link(sessionId, repositoryId);
    } on DataRefused catch (refusal) {
      throw SessionRepositoryException(refusal.message);
    }
  }

  /// Detaches a non-primary repository from a session.
  Future<void> detach(String sessionId, String repositoryId) async {
    try {
      await sessions.unlink(sessionId, repositoryId);
    } on DataRefused catch (refusal) {
      throw SessionRepositoryException(refusal.message);
    }
  }
}
