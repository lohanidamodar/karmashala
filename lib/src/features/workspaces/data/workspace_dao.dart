import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/workspace.dart';

/// Data-access for [Workspace] rows. Hand-written SQL, no codegen.
class WorkspaceDao {
  WorkspaceDao(this._db);

  final AppDatabase _db;

  void insert(Workspace workspace) {
    _db.execute(
      'INSERT INTO workspaces (id, name, description, created_at) '
      'VALUES (?, ?, ?, ?);',
      [
        workspace.id,
        workspace.name,
        workspace.description,
        isoFromDate(workspace.createdAt),
      ],
    );
  }

  /// The name and the description in **one** statement.
  ///
  /// They are edited together — the dialog's inline editor shows both fields at
  /// once — so writing them separately would make one user action two writes
  /// and leave a window in which the row held half of it.
  void updateDetails(String id, {required String name, String? description}) {
    _db.execute('UPDATE workspaces SET name = ?, description = ? WHERE id = ?;', [
      name,
      description,
      id,
    ]);
  }

  /// Removes the workspace. Its projects are **kept** and become unassigned —
  /// the `ON DELETE SET NULL` on `projects.workspace_id` does that, so there is
  /// no second statement here to forget.
  void delete(String id) {
    _db.execute('DELETE FROM workspaces WHERE id = ?;', [id]);
  }

  Workspace? getById(String id) {
    final rows = _db.query('SELECT * FROM workspaces WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every workspace, in the order the picker draws them: by name, the way a
  /// user scans a list of four things they named themselves.
  List<Workspace> getAll() => _db
      .query('SELECT * FROM workspaces ORDER BY name COLLATE NOCASE, id;')
      .map(_fromRow)
      .toList();

  Workspace _fromRow(Map<String, Object?> row) => Workspace(
    id: row['id']! as String,
    name: row['name']! as String,
    description: row['description'] as String?,
    createdAt: dateFromIso(row['created_at']),
  );
}
