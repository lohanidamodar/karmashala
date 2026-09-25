import 'package:karmashala_store/database.dart';

/// Where a repository sits, by name, for a phone's list.
typedef RepositoryPlace = ({
  String repositoryName,
  String projectId,
  String projectName,
  String projectPath,
});

/// The names a phone groups sessions and notes under, read straight from the
/// `projects` and `repositories` tables. Names only: what a project *is* stays
/// the app's, and a host answering while the app is closed needs no more than
/// what to call things.
class WorkspaceNames {
  WorkspaceNames(this._database);

  final AppDatabase _database;

  /// Every project's name, by id.
  Map<String, String> projects() => {
    for (final row in _database.query('SELECT id, name FROM projects;'))
      row['id']! as String: row['name']! as String,
  };

  /// Every repository's name and project, by id.
  Map<String, RepositoryPlace> repositories() => {
    for (final row in _database.query(
      'SELECT r.id AS id, r.name AS name, p.id AS project_id, '
      'p.name AS project_name, p.root_path AS project_path '
      'FROM repositories r JOIN projects p ON p.id = r.project_id;',
    ))
      row['id']! as String: (
        repositoryName: row['name']! as String,
        projectId: row['project_id']! as String,
        projectName: row['project_name']! as String,
        projectPath: row['project_path']! as String,
      ),
  };
}
