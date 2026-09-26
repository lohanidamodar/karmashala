import 'package:karmashala_store/database.dart';
import 'package:agent_cli/read.dart';

/// Data-access for imported CLI sessions. A conversation a native `sessions`
/// row records is *superseded*: hidden from every list here, never deleted.
class ImportedSessionDao {
  ImportedSessionDao(this._db);

  final AppDatabase _db;

  /// The one fact supersession turns on, written once so every read agrees.
  /// A NULL `external_session_id` matches nothing, which hides no history.
  static const String _nativeRowFor =
      'SELECT s.id FROM sessions s WHERE s.external_session_id = ';

  /// The `WHERE` clause that hides a conversation a native session row already
  /// represents.
  static const String _notSuperseded =
      'NOT EXISTS (${_nativeRowFor}imported_sessions.external_id)';

  /// The native row that took conversation [externalId] over, or null. Hiding a
  /// record from a list does not stop anyone opening it by id — open this.
  String? supersedingSessionId(String externalId) {
    final rows = _db.query(
      '$_nativeRowFor? ORDER BY s.created_at DESC LIMIT 1;',
      [externalId],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  /// Whether a native session row already records the conversation
  /// [externalId].
  bool isSuperseded(String externalId) =>
      supersedingSessionId(externalId) != null;

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

  /// Every record, superseded or not — a client's snapshot, which hides the
  /// superseded ones itself by the same rule (`visibleImported`).
  List<ImportedSession> everything() => _db
      .query('SELECT * FROM imported_sessions ORDER BY created_at, id;')
      .map(_fromRow)
      .toList();

  /// Every record [repositoryIds] hold, superseded or not — what a deleted
  /// project takes with it.
  List<String> idsUnder(Iterable<String> repositoryIds) {
    final ids = repositoryIds.toSet().toList();
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    return [
      for (final row in _db.query(
        'SELECT id FROM imported_sessions '
        'WHERE repository_id IN ($placeholders);',
        ids,
      ))
        row['id']! as String,
    ];
  }

  /// conversationId → its repository, for every record still showing as history.
  /// Two columns rather than a built [ImportedSession] per row.
  Map<String, String> repositoryIdsById() {
    final rows = _db.query(
      'SELECT id, repository_id FROM imported_sessions WHERE $_notSuperseded;',
    );
    return {
      for (final row in rows)
        row['id']! as String: row['repository_id']! as String,
    };
  }

  /// How many conversations under [repositoryIds] still show as history — the
  /// same rows [getByRepository] would return, counted rather than built.
  int countByRepositories(Iterable<String> repositoryIds) {
    final ids = repositoryIds.toSet().toList();
    if (ids.isEmpty) return 0;
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = _db.query(
      'SELECT COUNT(*) AS total FROM imported_sessions '
      'WHERE repository_id IN ($placeholders) AND $_notSuperseded;',
      ids,
    );
    return (rows.first['total'] as int?) ?? 0;
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
