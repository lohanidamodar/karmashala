import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_store/database.dart';

/// One `projects` row, as much of it as a phone is told.
typedef ProjectRow = ({
  String id,
  String name,
  EnvironmentPath root,
  DateTime createdAt,
});

/// The workspace as the session host reads it while no desktop app is
/// connected: the `projects`, `repositories`, `agent_installations` and
/// `execution_environments` rows, straight from the shared store, and the one
/// write a phone may ask for — a project and the checkouts found under it,
/// shaped exactly as the app's own `ProjectDao`/`RepositoryDao` write them.
class WorkspaceRows {
  WorkspaceRows(this._db);

  final AppDatabase _db;

  /// Every project, oldest first — the app's own order before pins.
  List<ProjectRow> projects() => [
    for (final row in _db.query(
      'SELECT * FROM projects ORDER BY created_at, id;',
    ))
      _project(row),
  ];

  ProjectRow? project(String id) {
    final rows = _db.query('SELECT * FROM projects WHERE id = ?;', [id]);
    return rows.isEmpty ? null : _project(rows.first);
  }

  /// [projectId]'s checkouts, oldest first.
  List<Repository> repositoriesOf(String projectId) => [
    for (final row in _db.query(
      'SELECT * FROM repositories WHERE project_id = ? '
      'ORDER BY created_at, id;',
      [projectId],
    ))
      _repository(row),
  ];

  /// Every agent installed in [environmentId], oldest first.
  List<AgentInstallation> installationsIn(String environmentId) => [
    for (final row in _db.query(
      'SELECT * FROM agent_installations WHERE environment_id = ? '
      'ORDER BY created_at, id;',
      [environmentId],
    ))
      _installation(row),
  ];

  /// Every agent installed anywhere, oldest first.
  List<AgentInstallation> installations() => [
    for (final row in _db.query(
      'SELECT * FROM agent_installations ORDER BY created_at, id;',
    ))
      _installation(row),
  ];

  List<ExecutionEnvironment> environments() => [
    for (final row in _db.query(
      'SELECT * FROM execution_environments ORDER BY created_at, id;',
    ))
      ExecutionEnvironment(
        id: row['id']! as String,
        kind: EnvironmentKind.values.byName(row['kind']! as String),
        name: row['name']! as String,
        wslDistribution: row['wsl_distribution'] as String?,
        sshHostId: row['ssh_host_id'] as String?,
        createdAt: dateFromIso(row['created_at']),
      ),
  ];

  /// Writes a project and its checkouts in one transaction: a project with
  /// only some of its checkouts is one a phone could start in the wrong place.
  void insertProject(ProjectRow project, List<Repository> repositories) {
    _db.transaction(() {
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
      for (final repository in repositories) {
        _db.execute(
          'INSERT INTO repositories '
          '(id, project_id, name, environment_id, path, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?);',
          [
            repository.id,
            repository.projectId,
            repository.name,
            repository.path.environmentId,
            repository.path.path,
            isoFromDate(repository.createdAt),
          ],
        );
      }
    });
  }

  static ProjectRow _project(Map<String, Object?> row) => (
    id: row['id']! as String,
    name: row['name']! as String,
    root: EnvironmentPath(
      environmentId: row['root_environment_id']! as String,
      path: row['root_path']! as String,
    ),
    createdAt: dateFromIso(row['created_at']),
  );

  static Repository _repository(Map<String, Object?> row) => Repository(
    id: row['id']! as String,
    projectId: row['project_id']! as String,
    name: row['name']! as String,
    path: EnvironmentPath(
      environmentId: row['environment_id']! as String,
      path: row['path']! as String,
    ),
    createdAt: dateFromIso(row['created_at']),
    canonicalId: row['canonical_id'] as String?,
  );

  static AgentInstallation _installation(Map<String, Object?> row) =>
      AgentInstallation(
        id: row['id']! as String,
        agentId: row['agent_kind']! as String,
        executable: EnvironmentPath(
          environmentId: row['environment_id']! as String,
          path: row['executable_path']! as String,
        ),
        version: row['version'] as String?,
        createdAt: dateFromIso(row['created_at']),
        executableByUser: boolFromInt(row['executable_by_user'] ?? 0),
      );
}
