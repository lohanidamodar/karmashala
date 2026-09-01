import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/session.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import '../domain/session_status.dart';
import '../../settings/domain/permission_mode.dart';

/// Data-access for [Session] rows. Hand-written SQL, no codegen.
class SessionDao {
  SessionDao(this._db);

  final AppDatabase _db;

  void insert(Session session) {
    _db.execute(
      'INSERT INTO sessions '
      '(id, repository_id, agent_installation_id, title, use_worktree, '
      'worktree_environment_id, worktree_path, '
      'working_directory_environment_id, working_directory_path, '
      'status, created_at, '
      'external_session_id, parent_session_id, parent_link_kind, pane_id, '
      'surface, view, permission_mode, archived_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        session.id,
        session.repositoryId,
        session.agentInstallationId,
        session.title,
        intFromBool(session.useWorktree),
        session.worktree?.environmentId,
        session.worktree?.path,
        session.workingDirectory?.environmentId,
        session.workingDirectory?.path,
        session.status.name,
        isoFromDate(session.createdAt),
        session.externalSessionId,
        session.parentSessionId,
        session.parentLink?.name,
        session.paneId,
        session.surface.name,
        session.view.name,
        session.permissionMode?.name,
        session.archivedAt == null ? null : isoFromDate(session.archivedAt!),
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

  /// Records the directory this session's agent runs in.
  ///
  /// Its own statement, like [updatePaneId], and for the same reason: where a
  /// session runs is learned once — at launch, or when a hand-started agent is
  /// adopted out of a pane — and must never be able to carry another edit with
  /// it. In particular it must never touch `worktree`, which drives
  /// `use_worktree` and the archive service's `git worktree remove`.
  void updateWorkingDirectory(String id, EnvironmentPath? directory) {
    _db.execute(
      'UPDATE sessions SET working_directory_environment_id = ?, '
      'working_directory_path = ? WHERE id = ?;',
      [directory?.environmentId, directory?.path, id],
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

  /// Records that this session's worktree has been archived away.
  ///
  /// Its own statement, and deliberately an `UPDATE` of one column: archiving
  /// must not be able to carry any other edit with it, and nothing here deletes
  /// anything. The transcript, review notes and checkpoints keep pointing at
  /// this row.
  void markArchived(String id, DateTime at) {
    _db.execute('UPDATE sessions SET archived_at = ? WHERE id = ?;', [
      isoFromDate(at),
      id,
    ]);
  }

  /// Records the permission mode chosen for this session, or with `null` that
  /// no mode is chosen for it and it follows the global default.
  ///
  /// Its own statement, like [updateView], and for the same reason: changing a
  /// session's safety policy must not be able to carry any other edit with it.
  ///
  /// Nullable because null is a *value* here and not a missing argument: "I
  /// never chose one for this session" is the state the owner's request turns
  /// on ("it should be highest priority to sessions own permission"), and a
  /// user who picks a mode must be able to go back to it.
  void updatePermissionMode(String id, PermissionMode? mode) {
    _db.execute('UPDATE sessions SET permission_mode = ? WHERE id = ?;', [
      mode?.name,
      id,
    ]);
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

  /// Sessions naming [id] as their parent, oldest first — spawned, handed off
  /// and forked alike. The caller reads [Session.parentLink] to tell them apart;
  /// filtering here would need one query per kind for no benefit.
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

  /// Every row recording the CLI conversation [externalSessionId], **newest
  /// first**.
  ///
  /// The column is a plain `TEXT` with no `UNIQUE` constraint
  /// (`migrations.dart:171`), unlike `imported_sessions`, so more than one row
  /// can name the same conversation — and one did, every time a stopped session
  /// was resumed. A caller that has to choose between them must be able to
  /// choose the same one twice, hence the total order: most recently started
  /// wins, and rows minted in the same instant fall back to the id so a fixed
  /// clock cannot make the answer arbitrary either.
  List<Session> getAllByExternalSessionId(String externalSessionId) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE external_session_id = ? '
      'ORDER BY created_at DESC, id DESC;',
      [externalSessionId],
    );
    return rows.map(_fromRow).toList();
  }

  /// The most recently started row for [externalSessionId], or `null`.
  ///
  /// Ordered rather than `LIMIT 1` on an unordered scan: see
  /// [getAllByExternalSessionId]. Callers that care whether the conversation is
  /// *running* must scan all of them — one row of several may be the live one —
  /// which is what `SessionLauncher.runningSessionWithExternalId` does.
  Session? getByExternalSessionId(String externalSessionId) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE external_session_id = ? '
      'ORDER BY created_at DESC, id DESC LIMIT 1;',
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

  /// Null-preserving, unlike [_surfaceFrom] and [_viewFrom], because null is a
  /// meaningful value here: a row written before schema v11 never recorded a
  /// mode, and falling back to `ask` would claim it ran under a policy it may
  /// well not have. The caller resolves that from the settings instead.
  static PermissionMode? _permissionFrom(String? value) {
    if (value == null) return null;
    for (final mode in PermissionMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }

  Session _fromRow(Map<String, Object?> row) {
    final worktreeEnv = row['worktree_environment_id'] as String?;
    final worktreePath = row['worktree_path'] as String?;
    final cwdEnv = row['working_directory_environment_id'] as String?;
    final cwdPath = row['working_directory_path'] as String?;
    return Session(
      id: row['id']! as String,
      repositoryId: row['repository_id']! as String,
      agentInstallationId: row['agent_installation_id']! as String,
      title: row['title']! as String,
      useWorktree: boolFromInt(row['use_worktree']),
      worktree: (worktreeEnv != null && worktreePath != null)
          ? EnvironmentPath(environmentId: worktreeEnv, path: worktreePath)
          : null,
      // Both halves or nothing: half a location is not one, and a path with no
      // environment is the bare string this codebase refuses to store.
      workingDirectory: (cwdEnv != null && cwdPath != null)
          ? EnvironmentPath(environmentId: cwdEnv, path: cwdPath)
          : null,
      status: SessionStatus.values.byName(row['status']! as String),
      createdAt: dateFromIso(row['created_at']),
      externalSessionId: row['external_session_id'] as String?,
      parentSessionId: row['parent_session_id'] as String?,
      parentLink: SessionLink.parse(row['parent_link_kind'] as String?),
      paneId: row['pane_id'] as String?,
      // Parsed by name with a fallback rather than `values.byName`, which throws
      // on anything it does not recognise — the failure mode that used to make a
      // fourth agent's rows unreadable (Loop 30).
      surface: _surfaceFrom(row['surface'] as String?),
      view: _viewFrom(row['view'] as String?),
      permissionMode: _permissionFrom(row['permission_mode'] as String?),
      archivedAt: row['archived_at'] == null
          ? null
          : dateFromIso(row['archived_at']),
    );
  }
}
