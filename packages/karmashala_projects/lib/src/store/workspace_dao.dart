import 'package:karmashala_store/database.dart';

import '../domain/workspace.dart';

/// Data-access for [Workspace] rows — contexts. Hand-written SQL, no codegen.
class WorkspaceDao {
  WorkspaceDao(this._db);

  final AppDatabase _db;

  void insert(Workspace workspace) {
    _db.execute(
      'INSERT INTO workspaces (id, name, description, color, created_at) '
      'VALUES (?, ?, ?, ?, ?);',
      [
        workspace.id,
        workspace.name,
        workspace.description,
        workspace.color,
        isoFromDate(workspace.createdAt),
      ],
    );
  }

  /// The name and the description in **one** statement: they are edited
  /// together, so two writes would leave a window holding half the change.
  void updateDetails(String id, {required String name, String? description}) {
    _db.execute(
      'UPDATE workspaces SET name = ?, description = ? WHERE id = ?;',
      [name, description, id],
    );
  }

  /// The colour's name, or null to clear it.
  void updateColor(String id, String? color) {
    _db.execute('UPDATE workspaces SET color = ? WHERE id = ?;', [color, id]);
  }

  /// Removes the workspace. Its projects are **kept** and become unassigned, by
  /// `ON DELETE SET NULL` — there is no second statement here to forget.
  void delete(String id) {
    _db.execute('DELETE FROM workspaces WHERE id = ?;', [id]);
  }

  Workspace? getById(String id) {
    final rows = _db.query('SELECT * FROM workspaces WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every workspace, in the order the picker draws them: by name.
  List<Workspace> getAll() => _db
      .query('SELECT * FROM workspaces ORDER BY name COLLATE NOCASE, id;')
      .map(_fromRow)
      .toList();

  Workspace _fromRow(Map<String, Object?> row) => Workspace(
    id: row['id']! as String,
    name: row['name']! as String,
    description: row['description'] as String?,
    color: row['color'] as String?,
    createdAt: dateFromIso(row['created_at']),
  );
}
