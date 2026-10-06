import 'package:agent_cli/process.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

/// Where a session's agent runs, for reading a path it names: its working
/// directory's environment, else its worktree's, else its checkout's.
class SessionEnvironments {
  SessionEnvironments(AppDatabase database)
    : _sessions = SessionDao(database),
      _repositories = RepositoryDao(database);

  final SessionDao _sessions;
  final RepositoryDao _repositories;

  /// Throws [StateError] for a session the store does not hold.
  String of(String sessionId) {
    final session =
        _sessions.getById(sessionId) ??
        (throw StateError('No session $sessionId.'));
    return session.workingDirectory?.environmentId ??
        session.worktree?.environmentId ??
        _repositories.getById(session.repositoryId)?.path.environmentId ??
        localHostEnvironmentId;
  }
}
