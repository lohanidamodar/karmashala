import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';

/// Data-access for the `session_repositories` link table (Loop 13).
class SessionRepositoryDao {
  SessionRepositoryDao(this._db);

  final AppDatabase _db;

  /// Links [repositoryId] to [sessionId] with [role]; a no-op if already linked.
  void link(
    String sessionId,
    String repositoryId, {
    String role = SessionRepositoryRole.additional,
  }) {
    _db.execute(
      'INSERT INTO session_repositories (session_id, repository_id, role) '
      'VALUES (?, ?, ?) ON CONFLICT(session_id, repository_id) DO NOTHING;',
      [sessionId, repositoryId, role],
    );
  }

  /// Removes a repository link (the primary cannot be removed here).
  void unlink(String sessionId, String repositoryId) {
    _db.execute(
      'DELETE FROM session_repositories '
      'WHERE session_id = ? AND repository_id = ? AND role != ?;',
      [sessionId, repositoryId, SessionRepositoryRole.primary],
    );
  }

  /// Links for [sessionId], primary first.
  List<SessionRepositoryLink> linksFor(String sessionId) {
    final rows = _db.query(
      'SELECT repository_id, role FROM session_repositories '
      "WHERE session_id = ? ORDER BY (role = 'primary') DESC, repository_id;",
      [sessionId],
    );
    return [for (final row in rows) _linkOf(row)];
  }

  /// Every session's links, primary first — a client's snapshot.
  Map<String, List<SessionRepositoryLink>> all() {
    final rows = _db.query(
      'SELECT session_id, repository_id, role FROM session_repositories '
      "ORDER BY session_id, (role = 'primary') DESC, repository_id;",
    );
    final bySession = <String, List<SessionRepositoryLink>>{};
    for (final row in rows) {
      (bySession[row['session_id']! as String] ??= []).add(_linkOf(row));
    }
    return bySession;
  }

  static SessionRepositoryLink _linkOf(Map<String, Object?> row) =>
      SessionRepositoryLink(
        repositoryId: row['repository_id']! as String,
        role: row['role']! as String,
      );
}
