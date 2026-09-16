import 'package:karmashala_store/database.dart';
import '../domain/todo.dart';

/// Data-access for the `todos` table (v33). Hand-written SQL, no codegen.
class TodoDao {
  TodoDao(this._db);

  final AppDatabase _db;

  void insert(Todo todo) {
    _db.execute(
      'INSERT INTO todos (id, body, done_at, project_id, position, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      [
        todo.id,
        todo.body,
        todo.doneAt == null ? null : isoFromDate(todo.doneAt!),
        todo.projectId,
        todo.position,
        isoFromDate(todo.createdAt),
      ],
    );
  }

  /// Rewrites the line. Its filing, its order and when it was done are facts
  /// the user set elsewhere, and fixing a typo must not disturb any of them.
  void updateBody(String id, String body) =>
      _db.execute('UPDATE todos SET body = ? WHERE id = ?;', [body, id]);

  /// Ticks it off at [doneAt], or reopens it when that is null.
  void setDone(String id, DateTime? doneAt) => _db.execute(
    'UPDATE todos SET done_at = ? WHERE id = ?;',
    [doneAt == null ? null : isoFromDate(doneAt), id],
  );

  /// Files [id] under [projectId], or unfiles it when null. Its own statement,
  /// so moving a todo cannot rewrite its text on the way.
  void setProject(String id, String? projectId) => _db.execute(
    'UPDATE todos SET project_id = ? WHERE id = ?;',
    [projectId, id],
  );

  /// Writes [ids] as positions `0..n-1`. The whole list rather than the two rows
  /// a move touches, so the stored order equals the screen's by construction.
  void reposition(List<String> ids) {
    _db.transaction(() {
      for (var i = 0; i < ids.length; i++) {
        _db.execute('UPDATE todos SET position = ? WHERE id = ?;', [i, ids[i]]);
      }
    });
  }

  void delete(String id) => _db.execute('DELETE FROM todos WHERE id = ?;', [id]);

  /// Removes every todo that is already done. The panel's one bulk action.
  int deleteDone() {
    final done = _db.query('SELECT id FROM todos WHERE done_at IS NOT NULL;');
    _db.execute('DELETE FROM todos WHERE done_at IS NOT NULL;');
    return done.length;
  }

  /// Open todos first in the user's order, then the done ones most recently
  /// finished first. One ordering for the panel, the MCP tool and the tests.
  List<Todo> list() => _db
      .query(
        'SELECT * FROM todos '
        'ORDER BY (done_at IS NULL) DESC, '
        'CASE WHEN done_at IS NULL THEN position END ASC, '
        'done_at DESC, id ASC;',
      )
      .map(_fromRow)
      .toList();

  Todo? getById(String id) {
    final rows = _db.query('SELECT * FROM todos WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The position a new todo goes to: the bottom, where you would write it on
  /// paper. The top is what you decided matters most.
  int nextPosition() {
    final rows = _db.query('SELECT MAX(position) AS top FROM todos;');
    final top = rows.isEmpty ? null : rows.first['top'];
    return top is int ? top + 1 : 0;
  }

  Todo _fromRow(Map<String, Object?> row) => Todo(
    id: row['id']! as String,
    body: row['body']! as String,
    projectId: row['project_id'] as String?,
    position: row['position']! as int,
    doneAt: row['done_at'] == null ? null : dateFromIso(row['done_at']),
    createdAt: dateFromIso(row['created_at']),
  );
}
