import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

/// The workspace as the session host reads it while no desktop app is
/// connected: the `projects` and `repositories` rows through the same DAOs
/// the server's data API writes them with, and the `agent_installations` and
/// `execution_environments` rows, straight from the shared store. Read-only:
/// a project a phone adds goes through the data API, so every client is told.
class WorkspaceRows {
  WorkspaceRows(this._db)
    : _projects = ProjectDao(_db),
      _repositories = RepositoryDao(_db);

  final AppDatabase _db;
  final ProjectDao _projects;
  final RepositoryDao _repositories;

  /// Every project, oldest first — the app's own order before pins.
  List<Project> projects() => _projects.getAll();

  Project? project(String id) => _projects.getById(id);

  /// [projectId]'s checkouts, oldest first.
  List<Repository> repositoriesOf(String projectId) =>
      _repositories.getByProject(projectId);

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
