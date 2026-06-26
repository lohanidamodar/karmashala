import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/project.dart';

/// Data-access for [Project] rows. Hand-written SQL, no codegen.
class ProjectDao {
  ProjectDao(this._db);

  final AppDatabase _db;

  void insert(Project project) {
    _db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at) '
      'VALUES (?, ?, ?, ?, ?);',
      [
        project.id,
        project.name,
        project.root.environmentId,
        project.root.path,
        isoFromDate(project.createdAt),
      ],
    );
  }

  void update(Project project) {
    _db.execute(
      'UPDATE projects SET name = ?, root_environment_id = ?, root_path = ? '
      'WHERE id = ?;',
      [project.name, project.root.environmentId, project.root.path, project.id],
    );
  }

  Project? getById(String id) {
    final rows = _db.query('SELECT * FROM projects WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<Project> getAll() {
    final rows = _db.query('SELECT * FROM projects ORDER BY created_at, id;');
    return rows.map(_fromRow).toList();
  }

  void delete(String id) {
    _db.execute('DELETE FROM projects WHERE id = ?;', [id]);
  }

  Project _fromRow(Map<String, Object?> row) => Project(
    id: row['id']! as String,
    name: row['name']! as String,
    root: EnvironmentPath(
      environmentId: row['root_environment_id']! as String,
      path: row['root_path']! as String,
    ),
    createdAt: dateFromIso(row['created_at']),
  );
}
