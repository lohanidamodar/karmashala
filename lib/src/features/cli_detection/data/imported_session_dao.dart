import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../agents/domain/agent_kind.dart';
import '../domain/imported_session.dart';

/// Data-access for imported CLI sessions. Hand-written SQL, no codegen.
class ImportedSessionDao {
  ImportedSessionDao(this._db);

  final AppDatabase _db;

  /// Inserts an imported session, ignoring it if `(source, external_id)` already
  /// exists. Returns `true` when a new row was written.
  bool insertIfAbsent(ImportedSession session) {
    if (getByExternal(session.cli, session.externalId) != null) return false;
    _db.execute(
      'INSERT INTO imported_sessions '
      '(id, repository_id, source, external_id, environment_id, title, '
      'preview, file_path, store_home, is_subagent, updated_at, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(source, external_id) DO NOTHING;',
      [
        session.id,
        session.repositoryId,
        session.cli.name,
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

  ImportedSession? getByExternal(AgentKind cli, String externalId) {
    final rows = _db.query(
      'SELECT * FROM imported_sessions WHERE source = ? AND external_id = ?;',
      [cli.name, externalId],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<ImportedSession> getAll() {
    final rows = _db.query(
      'SELECT * FROM imported_sessions '
      'ORDER BY updated_at DESC, created_at DESC;',
    );
    return rows.map(_fromRow).toList();
  }

  List<ImportedSession> getByRepository(String repositoryId) {
    final rows = _db.query(
      'SELECT * FROM imported_sessions WHERE repository_id = ? '
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
    cli: AgentKind.values.byName(row['source']! as String),
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
