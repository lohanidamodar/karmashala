import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:agent_cli/process.dart';
import '../domain/session.dart';
import '../domain/session_launch.dart';
import '../domain/session_lineage.dart';
import '../domain/session_status.dart';

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
      'surface, view, permission_mode, model_id, archived_at, title_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
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
        session.permissionMode,
        session.modelId,
        session.archivedAt == null ? null : isoFromDate(session.archivedAt!),
        intFromBool(session.titleByUser),
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

  /// Records the directory this session's agent runs in. Its own statement so
  /// it can never touch `worktree`, which drives the archive service's remove.
  void updateWorkingDirectory(String id, EnvironmentPath? directory) {
    _db.execute(
      'UPDATE sessions SET working_directory_environment_id = ?, '
      'working_directory_path = ? WHERE id = ?;',
      [directory?.environmentId, directory?.path, id],
    );
  }

  /// Renames session [id]. [byUser] records that the *user* chose this name,
  /// which is what stops the CLI rename sync ever replacing it.
  void updateTitle(String id, String title, {bool byUser = false}) {
    _db.execute(
      'UPDATE sessions SET title = ?, title_by_user = ? WHERE id = ?;',
      [title, intFromBool(byUser), id],
    );
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

  /// Records that this session's worktree has been archived away. One column,
  /// and nothing here deletes: the transcript still points at this row.
  void markArchived(String id, DateTime at) {
    _db.execute('UPDATE sessions SET archived_at = ? WHERE id = ?;', [
      isoFromDate(at),
      id,
    ]);
  }

  /// Records the permission mode chosen for this session. Null is a *value*
  /// here, not a missing argument: a user must be able to go back to it.
  void updatePermissionMode(String id, String? mode) {
    _db.execute('UPDATE sessions SET permission_mode = ? WHERE id = ?;', [
      mode,
      id,
    ]);
  }

  /// Records the model chosen for this session, or `null` to follow the
  /// default. `''` normalises to null — only one of them reads back as "none".
  void updateModel(String id, String? modelId) {
    _db.execute('UPDATE sessions SET model_id = ? WHERE id = ?;', [
      modelId == null || modelId.isEmpty ? null : modelId,
      id,
    ]);
  }

  /// The parent of [id], or `null` for a root session or an unknown id. One
  /// column, one row — this is the read `SessionDepth` walks, so it stays cheap.
  String? parentOf(String id) {
    final rows = _db.query(
      'SELECT parent_session_id FROM sessions WHERE id = ?;',
      [id],
    );
    return rows.isEmpty ? null : rows.first['parent_session_id'] as String?;
  }

  /// Sessions naming [id] as their parent, oldest first — spawned, handed off
  /// and forked alike; the caller reads [Session.parentLink] to tell them apart.
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

  /// Sessions hosted by any of [paneIds], oldest first. The pane index keeps
  /// this proportional to that tab's panes, not to every session ever opened.
  List<Session> getByPaneIds(Iterable<String> paneIds) {
    final ids = paneIds.toSet().toList();
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _db.query(
      'SELECT * FROM sessions WHERE pane_id IN ($placeholders) '
      'ORDER BY created_at, id;',
      ids,
    );
    return rows.map(_fromRow).toList();
  }

  /// paneId → the session standing in it, for every placed row at once: one
  /// statement over the pane index, so one pane's answer cannot wake the others.
  Map<String, String> paneSessionIds() {
    final rows = _db.query(
      'SELECT id, pane_id FROM sessions WHERE pane_id IS NOT NULL '
      'ORDER BY created_at, id;',
    );
    final byPane = <String, String>{};
    for (final row in rows) {
      byPane.putIfAbsent(row['pane_id']! as String, () => row['id']! as String);
    }
    return byPane;
  }

  /// sessionId → the repository it targets, for every row at once. Taken off
  /// [getAll] it decoded twenty-one columns and an ISO date to read two.
  Map<String, String> repositoryIdsById() {
    final rows = _db.query('SELECT id, repository_id FROM sessions;');
    return {
      for (final row in rows)
        row['id']! as String: row['repository_id']! as String,
    };
  }

  /// Every row whose status still claims something is running, oldest first.
  /// The words come from [SessionStatus.claimsLive], so a seventh is swept too.
  List<Session> getClaimingLive() {
    final names = [
      for (final status in SessionStatus.values)
        if (status.claimsLive) status.name,
    ];
    final placeholders = List.filled(names.length, '?').join(', ');
    final rows = _db.query(
      'SELECT * FROM sessions WHERE status IN ($placeholders) '
      'ORDER BY created_at, id;',
      names,
    );
    return rows.map(_fromRow).toList();
  }

  /// Every row recording the CLI conversation [externalSessionId], **newest
  /// first**: the column has no `UNIQUE` constraint, so duplicates are real.
  List<Session> getAllByExternalSessionId(String externalSessionId) {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE external_session_id = ? '
      'ORDER BY created_at DESC, id DESC;',
      [externalSessionId],
    );
    return rows.map(_fromRow).toList();
  }

  /// The most recently started row for [externalSessionId], or `null`. A caller
  /// that needs the *running* one must scan them all — any of them may be it.
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

  /// All external session IDs currently held by active sessions. Projects one
  /// column instead of deserializing full session objects.
  Set<String> heldExternalSessionIds({String? excludingSessionId}) {
    final results = excludingSessionId == null
        ? _db.query(
            'SELECT external_session_id FROM sessions '
            "WHERE external_session_id IS NOT NULL AND external_session_id != '';",
          )
        : _db.query(
            'SELECT external_session_id FROM sessions '
            'WHERE id != ? '
            "AND external_session_id IS NOT NULL AND external_session_id != '';",
            [excludingSessionId],
          );
    return {
      for (final row in results)
        if (row['external_session_id'] is String)
          row['external_session_id'] as String,
    };
  }

  /// Active, non-archived sessions that have an external session ID and
  /// whose title was not typed by the user, waiting for title synchronization.
  List<Session> getWaitingForTitleSync() {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE archived_at IS NULL AND title_by_user = 0 '
      "AND external_session_id IS NOT NULL AND external_session_id != '' "
      'ORDER BY created_at, id;',
    );
    return rows.map(_fromRow).toList();
  }

  /// Active, non-archived sessions that are still waiting for an external session ID.
  List<Session> getUnattributed() {
    final rows = _db.query(
      'SELECT * FROM sessions WHERE archived_at IS NULL '
      "AND (external_session_id IS NULL OR external_session_id = '') "
      'ORDER BY created_at, id;',
    );
    return rows.map(_fromRow).toList();
  }

  /// The rows named by [ids], oldest first, in one indexed query. For callers
  /// reaching for [getAll] only to build a lookup map; a scan costs every row.
  List<Session> getByIds(Iterable<String> ids) {
    final unique = ids.toSet().toList();
    if (unique.isEmpty) return const [];
    final placeholders = List.filled(unique.length, '?').join(', ');
    final rows = _db.query(
      'SELECT * FROM sessions WHERE id IN ($placeholders) '
      'ORDER BY created_at, id;',
      unique,
    );
    return rows.map(_fromRow).toList();
  }

  /// How many sessions sit under [repositoryIds], and how many are running, in
  /// **one statement that decodes no session at all**. A header never names one.
  ({int sessions, int running}) countsByRepositories(
    Iterable<String> repositoryIds,
  ) {
    final ids = repositoryIds.toSet().toList();
    if (ids.isEmpty) return (sessions: 0, running: 0);
    final placeholders = List.filled(ids.length, '?').join(', ');
    final row = _db.query(
      'SELECT COUNT(*) AS total, '
      'COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS running '
      'FROM sessions WHERE repository_id IN ($placeholders);',
      [SessionStatus.running.name, ...ids],
    ).first;
    return (
      sessions: (row['total'] as int?) ?? 0,
      running: (row['running'] as int?) ?? 0,
    );
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

  /// The row's lifecycle word, or [SessionStatus.unknown] for one this build
  /// cannot read — rather than one bad word throwing the whole `SELECT` away.
  static SessionStatus _statusFrom(String? value) {
    for (final status in SessionStatus.values) {
      if (status.name == value) return status;
    }
    return SessionStatus.unknown;
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
      status: _statusFrom(row['status'] as String?),
      createdAt: dateFromIso(row['created_at']),
      externalSessionId: row['external_session_id'] as String?,
      parentSessionId: row['parent_session_id'] as String?,
      parentLink: SessionLink.parse(row['parent_link_kind'] as String?),
      paneId: row['pane_id'] as String?,
      // Parsed by name with a fallback rather than `values.byName`, which
      // throws and used to make a fourth agent's rows unreadable (Loop 30).
      surface: _surfaceFrom(row['surface'] as String?),
      view: _viewFrom(row['view'] as String?),
      // Kept verbatim rather than parsed: since v35 this is the agent's own
      // vocabulary, and a DAO that "validated" it would throw the row away.
      permissionMode: row['permission_mode'] as String?,
      modelId: row['model_id'] as String?,
      archivedAt: row['archived_at'] == null
          ? null
          : dateFromIso(row['archived_at']),
      titleByUser: boolFromInt(row['title_by_user']),
    );
  }
}
