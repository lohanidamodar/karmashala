import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/data/repository_discovery_service.dart';
import '../../repositories/data/repository_dao.dart';
import '../../repositories/domain/repository.dart';
import '../data/project_dao.dart';
import '../domain/project.dart';

/// Outcome of creating a project: the persisted [project] and the repositories
/// discovered (and persisted) within its root folder.
class ProjectCreationResult {
  const ProjectCreationResult({
    required this.project,
    required this.repositories,
  });
  final Project project;
  final List<Repository> repositories;
}

/// Application use-cases for projects: creating a project at a folder and
/// discovering the Git repositories inside it.
class ProjectService {
  ProjectService({
    required this.projectDao,
    required this.repositoryDao,
    required this.discovery,
    required this.ids,
    required this.clock,
  });

  final ProjectDao projectDao;
  final RepositoryDao repositoryDao;
  final RepositoryDiscoveryService discovery;
  final IdGenerator ids;
  final Clock clock;

  /// Creates a project rooted at [root] named [name], discovers Git repositories
  /// beneath it, and persists everything. The whole operation is atomic only at
  /// the row level; discovery failures propagate as
  /// [RepositoryDiscoveryException] before any repository rows are written.
  Future<ProjectCreationResult> createProjectByDiscovery({
    required String name,
    required EnvironmentPath root,
    int maxDepth = 5,
  }) async {
    final now = clock.nowUtc();
    final project = Project(
      id: ids.newId(),
      name: name,
      root: root,
      createdAt: now,
    );

    // Discover first so a bad folder fails before we persist a partial project.
    final discovered = await discovery.discover(root, maxDepth: maxDepth);

    projectDao.insert(project);
    final repositories = <Repository>[];
    for (final d in discovered) {
      final repo = Repository(
        id: ids.newId(),
        projectId: project.id,
        name: d.name,
        path: d.path,
        createdAt: now,
      );
      repositoryDao.insert(repo);
      repositories.add(repo);
    }

    return ProjectCreationResult(project: project, repositories: repositories);
  }

  /// Re-runs discovery for an existing [project] and persists any repositories
  /// not already recorded (matched by path). Returns the newly added rows.
  Future<List<Repository>> rediscover(
    Project project, {
    int maxDepth = 5,
  }) async {
    final existing = repositoryDao
        .getByProject(project.id)
        .map((r) => r.path)
        .toSet();
    final discovered = await discovery.discover(
      project.root,
      maxDepth: maxDepth,
    );
    final now = clock.nowUtc();
    final added = <Repository>[];
    for (final d in discovered) {
      if (existing.contains(d.path)) continue;
      final repo = Repository(
        id: ids.newId(),
        projectId: project.id,
        name: d.name,
        path: d.path,
        createdAt: now,
      );
      repositoryDao.insert(repo);
      added.add(repo);
    }
    return added;
  }
}
