import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/session.dart';
import '../domain/session_launch.dart';
import '../domain/session_status.dart';

/// Data-access for [Session] rows. Hand-written SQL, no codegen.
class SessionDao {
  SessionDao(this._db);

  final AppDatabase _db;

  void insert(Session session) {
    _db.execute(
      'INSERT INTO sessions '
      '(id, repository_id, agent_installation_id, title, use_worktree, '
      'worktree_environment_id, worktree_path, status, created_at, '
      'external_session_id, parent_session_id, pane_id, surface, view) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        session.id,
        session.repositoryId,
        session.agentInstallationId,
        session.title,
        intFromBool(session.useWorktree),
        session.worktree?.environmentId,
        session.worktree?.path,
        session.status.name,
        isoFromDate(session.createdAt),
        session.externalSessionId,
        session.parentSessionId,
        session.paneId,
        session.surface.name,
        session.view.name,
      ],
    );
  }

  /// Updates the mutable fields of a session (title, worktree, status).
  void update(Session session) {
    _db.execute(
      'UPDATE sessions SET title = ?, use_worktree = ?, '
      'worktree_environment_id = ?, worktree_path = ?, status = ? '
      'WHERE id = ?;',
      [
        session.title,
        intFromBool(session.useWorktree),
        session.worktree?.environmentId,
        session.worktree?.path,
        session.status.name,
        session.id,
      ],
    );
  }

  /// Updates only the [title] of session [id].
  void updateTitle(String id, String title) {
    _db.execute('UPDATE sessions SET title = ? WHERE id = ?;', [title, id]);
  }

  /// Updates only the [status] of session [id].
  void updateStatus(String id, SessionStatus status) {
    _db.execute('UPDATE sessions SET status = ? WHERE id = ?;', [
      status.name,
      id,
    ]);
  }

  /// Records which pane a session's PTY is in. Separate from [update] because
  /// it is written once, when the pane is created, and never as part of an edit.
  void updatePaneId(String id, String? paneId) {
    _db.execute('UPDATE sessions SET pane_id = ? WHERE id = ?;', [paneId, id]);
  }

  /// Flips which of the two views a session is drawn in. Deliberately its own
  /// statement: a view change must never be able to touch anything else.
  void updateView(String id, SessionView view) {
    _db.execute('UPDATE sessions SET view = ? WHERE id = ?;', [view.name, id]);
  }

  /// The parent of [id], or `null` for a root session or an unknown id.
  ///
  /// One column, one row — this is the read `SessionDepth` walks, so it must
  /// stay this cheap.
  String? parentOf(String id) {
    final rows = _db.query(
      'SELECT parent_session_id FROM sessions WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : rows.first['parent_session_id'] as String?;
  }

  /// Sessions spawned directly by [id], newest last.
  List<Session> childrenOf(String id) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE parent_session_id = ? '
      'ORDER BY created_at, id;',
      [id],
    );
    return rows.map(_fromRow).toList();
  }

  void updateExternalSessionId(String id, String externalSessionId) {
    _db.execute('UPDATE sessions SET external_session_id = ? WHERE id = ?;', [
      externalSessionId,
      id,
    ]);
  }

  Session? getById(String id) {
    final rows = _db.query('SELECT * FROM sessions WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Session? getByExternalSessionId(String externalSessionId) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE external_session_id = ? LIMIT 1;',
      [externalSessionId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<Session> getAll() {
    final rows = _db.query('SELECT * FROM sessions ORDER BY created_at, id;');
    return rows.map(_fromRow).toList();
  }

  /// Sessions targeting [repositoryId].
  List<Session> getByRepository(String repositoryId) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE repository_id = ? ORDER BY created_at, id;',
      [repositoryId],
    );
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM sessions WHERE id = ?;', [id]);
  }

  static SessionSurface _surfaceFrom(String? value) {
    for (final surface in SessionSurface.values) {
      if (surface.name == value) return surface;
    }
    return SessionSurface.external;
  }

  static SessionView _viewFrom(String? value) {
    for (final view in SessionView.values) {
      if (view.name == value) return view;
    }
    return SessionView.terminal;
  }

  Session _fromRow(Map<String, Object?> row) {
    final worktreeEnv = row['worktree_environment_id'] as String?;
    final worktreePath = row['worktree_path'] as String?;
    return Session(
      id: row['id']! as String,
      repositoryId: row['repository_id']! as String,
      agentInstallationId: row['agent_installation_id']! as String,
      title: row['title']! as String,
      useWorktree: boolFromInt(row['use_worktree']),
      worktree: (worktreeEnv != null && worktreePath != null)
          ? EnvironmentPath(environmentId: worktreeEnv, path: worktreePath)
          : null,
      status: SessionStatus.values.byName(row['status']! as String),
      createdAt: dateFromIso(row['created_at']),
      externalSessionId: row['external_session_id'] as String?,
      parentSessionId: row['parent_session_id'] as String?,
      paneId: row['pane_id'] as String?,
      // Parsed by name with a fallback rather than `values.byName`, which throws
      // on anything it does not recognise — the failure mode that used to make a
      // fourth agent's rows unreadable (Loop 30).
      surface: _surfaceFrom(row['surface'] as String?),
      view: _viewFrom(row['view'] as String?),
    );
  }
}
