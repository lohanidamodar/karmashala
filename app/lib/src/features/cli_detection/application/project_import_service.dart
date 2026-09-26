import 'package:karmashala_core/util.dart';
import 'package:agent_cli/process.dart';
import '../../projects/data/project_dao.dart';
import '../../projects/domain/project.dart';
import '../../repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import '../data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';

/// Counts of what an import added (duplicates are not counted).
class ImportSummary {
  const ImportSummary({
    this.projects = 0,
    this.repositories = 0,
    this.sessions = 0,
  });
  final int projects;
  final int repositories;
  final int sessions;

  ImportSummary operator +(ImportSummary other) => ImportSummary(
    projects: projects + other.projects,
    repositories: repositories + other.repositories,
    sessions: sessions + other.sessions,
  );

  bool get isEmpty => projects == 0 && repositories == 0 && sessions == 0;
}

/// Imports detected CLI projects/sessions into the workspace, finding or
/// creating a `Project` and `Repository` per folder. Idempotent.
class ProjectImportService {
  ProjectImportService({
    required this.projectDao,
    required this.repositoryDao,
    required this.importedSessionDao,
    required this.ids,
    required this.clock,
  });

  final ProjectDao projectDao;
  final RepositoryDao repositoryDao;
  final ImportedSessionDao importedSessionDao;
  final IdGenerator ids;
  final Clock clock;

  ImportSummary importAll(List<DetectedProject> detected) {
    var summary = const ImportSummary();
    for (final project in detected) {
      summary = summary + _importOne(project);
    }
    return summary;
  }

  ImportSummary _importOne(DetectedProject detected) {
    final all = [...detected.sessions, ...detected.subagentSessions];
    if (all.isEmpty) return const ImportSummary();
    final root = all.first.cwd;
    final now = clock.nowUtc();

    var addedProjects = 0;
    var addedRepos = 0;
    var addedSessions = 0;

    var project = _findProjectByRoot(root);
    if (project == null) {
      project = Project(
        id: ids.newId(),
        name: _basename(root.path),
        root: root,
        createdAt: now,
      );
      projectDao.insert(project);
      addedProjects = 1;
    }

    var repository = _findRepository(project.id, root);
    if (repository == null) {
      repository = Repository(
        id: ids.newId(),
        projectId: project.id,
        name: _basename(root.path),
        path: root,
        createdAt: now,
      );
      repositoryDao.insert(repository);
      addedRepos = 1;
    }

    for (final session in all) {
      if (_importSession(session, repository.id, now)) addedSessions++;
    }

    return ImportSummary(
      projects: addedProjects,
      repositories: addedRepos,
      sessions: addedSessions,
    );
  }

  bool _importSession(
    DetectedSession session,
    String repositoryId,
    DateTime now,
  ) {
    if (importedSessionDao.getByExternal(session.cli, session.sessionId) !=
        null) {
      return false; // duplicate — ignore
    }
    return importedSessionDao.insertIfAbsent(
      ImportedSession(
        id: ids.newId(),
        repositoryId: repositoryId,
        cli: session.cli,
        externalId: session.sessionId,
        environmentId: session.environmentId,
        filePath: session.filePath,
        storeHome: session.storeHome,
        isSubagent: session.isSubagent,
        preview: session.preview,
        title: session.title,
        updatedAt: session.modifiedAt,
        createdAt: now,
      ),
    );
  }

  Project? _findProjectByRoot(EnvironmentPath root) {
    for (final project in projectDao.getAll()) {
      if (project.root == root) return project;
    }
    return null;
  }

  Repository? _findRepository(String projectId, EnvironmentPath path) {
    for (final repo in repositoryDao.getByProject(projectId)) {
      if (repo.path == path) return repo;
    }
    return null;
  }

  static String _basename(String path) {
    final parts = path
        .replaceAll(RegExp(r'[\\/]+$'), '')
        .split(RegExp(r'[\\/]'));
    return parts.isEmpty || parts.last.isEmpty ? path : parts.last;
  }
}
