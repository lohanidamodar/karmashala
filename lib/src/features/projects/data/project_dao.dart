import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import '../domain/project.dart';

/// Data-access for [Project] rows. Hand-written SQL, no codegen.
class ProjectDao {
  ProjectDao(this._db);

  final AppDatabase _db;

  void insert(Project project) {
    _db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at, workspace_id, '
      'default_repository_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        project.id,
        project.name,
        project.root.environmentId,
        project.root.path,
        isoFromDate(project.createdAt),
        project.workspaceId,
        project.defaultRepositoryId,
      ],
    );
  }

  void update(Project project) {
    _db.execute(
      'UPDATE projects SET name = ?, root_environment_id = ?, root_path = ?, '
      'workspace_id = ?, default_repository_id = ? WHERE id = ?;',
      [
        project.name,
        project.root.environmentId,
        project.root.path,
        project.workspaceId,
        project.defaultRepositoryId,
        project.id,
      ],
    );
  }

  /// Files [id] under [workspaceId], or unassigns it when null. Its own
  /// statement, so a move cannot rewrite the project's name or root on the way.
  void setWorkspace(String id, String? workspaceId) {
    _db.execute('UPDATE projects SET workspace_id = ? WHERE id = ?;', [
      workspaceId,
      id,
    ]);
  }

  /// Points [id]'s one-click "New session" at [repositoryId], or back at the
  /// picker's first row when null. Its own statement, for [setWorkspace]'s
  /// reason: choosing a checkout must not rewrite the name or the root.
  void setDefaultRepository(String id, String? repositoryId) {
    _db.execute(
      'UPDATE projects SET default_repository_id = ? WHERE id = ?;',
      [repositoryId, id],
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

  /// Names of the projects that keep [environmentId]'s row from being deleted,
  /// sorted. Each clause is a RESTRICT on the way down: a project rooted there,
  /// a repository there, or a session run by an agent installed there (the
  /// installation cascades with the environment, the session does not let it).
  List<String> namesUsingEnvironment(String environmentId) {
    final rows = _db.query(
      'SELECT DISTINCT p.name FROM projects p '
      'WHERE p.root_environment_id = ?1 '
      'OR p.id IN (SELECT project_id FROM repositories WHERE environment_id = ?1) '
      'OR p.id IN (SELECT r.project_id FROM sessions s '
      'JOIN repositories r ON r.id = s.repository_id '
      'JOIN agent_installations a ON a.id = s.agent_installation_id '
      'WHERE a.environment_id = ?1) '
      'ORDER BY p.name;',
      [environmentId],
    );
    return [for (final row in rows) row['name']! as String];
  }

  Project _fromRow(Map<String, Object?> row) => Project(
    id: row['id']! as String,
    name: row['name']! as String,
    root: EnvironmentPath(
      environmentId: row['root_environment_id']! as String,
      path: row['root_path']! as String,
    ),
    createdAt: dateFromIso(row['created_at']),
    workspaceId: row['workspace_id'] as String?,
    defaultRepositoryId: row['default_repository_id'] as String?,
  );
}
