import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/imported_session.dart';

/// Data-access for imported CLI sessions. Hand-written SQL, no codegen.
///
/// ## One conversation, one row
///
/// Two tables can hold a record of the same CLI session: `imported_sessions`,
/// which is history read off the agent's own store, and `sessions`, whose
/// `external_session_id` names the conversation a live row is running. Resuming
/// an imported session produces the second while the first still exists, and
/// the Explorer drew both — one conversation, two cards, with the CLI itself
/// reporting a single session.
///
/// **The tie is resolved here, at the source, rather than filtered in each
/// view.** A conversation that has a native row is *superseded*: the native row
/// can resume, rename, fork and hand off, reaches the same transcript through
/// the same id, and carries the title and repository the imported record was
/// created with — so it is strictly the better representation and the imported
/// one has nothing left to add. Every list read below excludes superseded rows
/// and [insertIfAbsent] refuses to write one, which is what makes this
/// impossible to forget in a new caller.
///
/// The superseded row is **hidden, not deleted**. It costs nothing, and it is
/// what history falls back to if the native row is ever removed — deleting a
/// user's record to fix a display bug is the wrong trade.
///
/// [getById] and [getByExternal] are deliberately *not* filtered: those are
/// identity lookups, used to resolve a selection, to dedupe an import, and by
/// adoption to find the record it is replacing.
class ImportedSessionDao {
  ImportedSessionDao(this._db);

  final AppDatabase _db;

  /// The `WHERE` clause that hides a conversation a native session row already
  /// represents. Written once so the list reads cannot drift apart.
  static const String _notSuperseded =
      'NOT EXISTS (SELECT 1 FROM sessions s '
      'WHERE s.external_session_id = imported_sessions.external_id)';

  /// Whether a native session row already records the conversation
  /// [externalId].
  bool isSuperseded(String externalId) => _db
      .query('SELECT 1 FROM sessions WHERE external_session_id = ? LIMIT 1;', [
        externalId,
      ])
      .isNotEmpty;

  /// Inserts an imported session, ignoring it if `(source, external_id)` already
  /// exists **or a native session row already represents that conversation**.
  /// Returns `true` when a new row was written.
  bool insertIfAbsent(ImportedSession session) {
    if (getByExternal(session.cli, session.externalId) != null) return false;
    if (isSuperseded(session.externalId)) return false;
    _db.execute(
      'INSERT INTO imported_sessions '
      '(id, repository_id, source, external_id, environment_id, title, '
      'preview, file_path, store_home, is_subagent, updated_at, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(source, external_id) DO NOTHING;',
      [
        session.id,
        session.repositoryId,
        session.cli,
        session.externalId,
        session.environmentId,
        session.title,
        session.preview,
        session.filePath,
        session.storeHome,
        intFromBool(session.isSubagent),
        session.updatedAt == null ? null : isoFromDate(session.updatedAt!),
        isoFromDate(session.createdAt),
      ],
    );
    return true;
  }

  ImportedSession? getById(String id) {
    final rows = _db.query('SELECT * FROM imported_sessions WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  ImportedSession? getByExternal(String cli, String externalId) {
    final rows = _db.query(
      'SELECT * FROM imported_sessions WHERE source = ? AND external_id = ?;',
      [cli, externalId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<ImportedSession> getAll() {
    final rows = _db.query(
      'SELECT * FROM imported_sessions WHERE $_notSuperseded '
      'ORDER BY updated_at DESC, created_at DESC;',
    );
    return rows.map(_fromRow).toList();
  }

  List<ImportedSession> getByRepository(String repositoryId) {
    final rows = _db.query(
      'SELECT * FROM imported_sessions WHERE repository_id = ? '
      'AND $_notSuperseded '
      'ORDER BY updated_at DESC, created_at DESC;',
      [repositoryId],
    );
    return rows.map(_fromRow).toList();
  }

  void updateTitle(String id, String title) {
    _db.execute('UPDATE imported_sessions SET title = ? WHERE id = ?;', [
      title,
      id,
    ]);
  }

  void delete(String id) {
    _db.execute('DELETE FROM imported_sessions WHERE id = ?;', [id]);
  }

  ImportedSession _fromRow(Map<String, Object?> row) => ImportedSession(
    id: row['id']! as String,
    repositoryId: row['repository_id']! as String,
    cli: row['source']! as String,
    externalId: row['external_id']! as String,
    environmentId: row['environment_id']! as String,
    title: row['title'] as String?,
    preview: row['preview']! as String,
    filePath: row['file_path']! as String,
    storeHome: row['store_home']! as String,
    isSubagent: boolFromInt(row['is_subagent']),
    updatedAt: row['updated_at'] == null
        ? null
        : dateFromIso(row['updated_at']),
    createdAt: dateFromIso(row['created_at']),
  );
}
