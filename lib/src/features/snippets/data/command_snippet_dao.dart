import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/command_snippet.dart';

/// Data-access for the `command_snippets` table (v32). Hand-written SQL, no
/// codegen, the same shape as `NoteDao`.
class CommandSnippetDao {
  CommandSnippetDao(this._db);

  final AppDatabase _db;

  void insert(CommandSnippet snippet) {
    _db.execute(
      'INSERT INTO command_snippets '
      '(id, label, command, shell, submit, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        snippet.id,
        snippet.label,
        snippet.command,
        snippet.shellId,
        intFromBool(snippet.submit),
        isoFromDate(snippet.createdAt),
        isoFromDate(snippet.updatedAt),
      ],
    );
  }

  void update(
    String id, {
    required String label,
    required String command,
    required String? shellId,
    required bool submit,
    required DateTime updatedAt,
  }) {
    _db.execute(
      'UPDATE command_snippets SET label = ?, command = ?, shell = ?, '
      'submit = ?, updated_at = ? WHERE id = ?;',
      [label, command, shellId, intFromBool(submit), isoFromDate(updatedAt), id],
    );
  }

  void delete(String id) =>
      _db.execute('DELETE FROM command_snippets WHERE id = ?;', [id]);

  /// Every snippet, oldest first.
  ///
  /// Insertion order rather than a `position` column: the palette ranks by
  /// match score and this order only decides what an *empty* query lists, so a
  /// reorder column would be a schema and an API paid for by one list nobody
  /// drags. `created_at, id` is stable across a clock that repeats — two
  /// snippets saved in the same millisecond still have an order.
  List<CommandSnippet> list() => _db
      .query('SELECT * FROM command_snippets ORDER BY created_at, id;')
      .map(_fromRow)
      .toList();

  CommandSnippet? getById(String id) {
    final rows = _db.query('SELECT * FROM command_snippets WHERE id = ?;', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  CommandSnippet _fromRow(Map<String, Object?> row) => CommandSnippet(
    id: row['id']! as String,
    label: row['label']! as String,
    command: row['command']! as String,
    shellId: row['shell'] as String?,
    submit: boolFromInt(row['submit']),
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
  );
}
