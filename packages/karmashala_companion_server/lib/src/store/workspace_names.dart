import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

/// Where a repository sits, by name, for a phone's list.
typedef RepositoryPlace = ({
  String repositoryName,
  String projectId,
  String projectName,
  String projectPath,
});

/// The names a phone groups sessions and notes under, read through the same
/// DAOs the server's data API writes the workspace with. Names only: a host
/// answering while the app is closed needs no more than what to call things.
class WorkspaceNames {
  WorkspaceNames(AppDatabase database)
    : _projects = ProjectDao(database),
      _repositories = RepositoryDao(database);

  final ProjectDao _projects;
  final RepositoryDao _repositories;

  /// Every project's name, by id.
  Map<String, String> projects() => {
    for (final project in _projects.getAll()) project.id: project.name,
  };

  /// Every repository's name and project, by id.
  Map<String, RepositoryPlace> repositories() {
    final projects = {for (final p in _projects.getAll()) p.id: p};
    return {
      for (final repository in _repositories.getAll())
        if (projects[repository.projectId] case final project?)
          repository.id: (
            repositoryName: repository.name,
            projectId: project.id,
            projectName: project.name,
            projectPath: project.root.path,
          ),
    };
  }
}
