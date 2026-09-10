import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/note.dart';

/// Data-access for the `notes` table (v21). Hand-written SQL, no codegen.
class NoteDao {
  NoteDao(this._db);

  final AppDatabase _db;

  void insert(Note note) {
    _db.execute(
      'INSERT INTO notes '
      '(id, title, body, project_id, source_session_id, source_repository_id, '
      'source_message_ordinal, source_message_role, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        note.id,
        note.title,
        note.body,
        note.projectId,
        note.sourceSessionId,
        note.sourceRepositoryId,
        note.sourceMessageOrdinal,
        note.sourceMessageRole,
        isoFromDate(note.createdAt),
        isoFromDate(note.updatedAt),
      ],
    );
  }

  /// Rewrites what the user changed. The origin columns are never touched —
  /// where a note came from is a fact about the past. Its *filing* is not.
  void update(
    String id, {
    required String body,
    required String? title,
    required String? projectId,
    required DateTime updatedAt,
  }) {
    _db.execute(
      'UPDATE notes SET title = ?, body = ?, project_id = ?, updated_at = ? '
      'WHERE id = ?;',
      [title, body, projectId, isoFromDate(updatedAt), id],
    );
  }

  /// Files [id] under [projectId], or unfiles it when null. Its own statement,
  /// so re-filing a note cannot rewrite its text on the way.
  void setProject(String id, String? projectId) => _db.execute(
    'UPDATE notes SET project_id = ? WHERE id = ?;',
    [projectId, id],
  );

  void delete(String id) =>
      _db.execute('DELETE FROM notes WHERE id = ?;', [id]);

  /// Newest first — a note list is a stack of things not done yet, so the
  /// thought you had a minute ago is the one at the top.
  List<Note> list({String? sessionId}) {
    final rows = sessionId == null
        ? _db.query('SELECT * FROM notes ORDER BY created_at DESC, id DESC;')
        : _db.query(
            'SELECT * FROM notes WHERE source_session_id = ? '
            'ORDER BY created_at DESC, id DESC;',
            [sessionId],
          );
    return rows.map(_fromRow).toList();
  }

  Note? getById(String id) {
    final rows = _db.query('SELECT * FROM notes WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Note _fromRow(Map<String, Object?> row) => Note(
    id: row['id']! as String,
    title: row['title'] as String?,
    body: row['body']! as String,
    projectId: row['project_id'] as String?,
    sourceSessionId: row['source_session_id'] as String?,
    sourceRepositoryId: row['source_repository_id'] as String?,
    sourceMessageOrdinal: row['source_message_ordinal'] as int?,
    sourceMessageRole: row['source_message_role'] as String?,
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
  );
}
