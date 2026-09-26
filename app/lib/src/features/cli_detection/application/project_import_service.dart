import 'package:karmashala_core/util.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../../workspaces/data/workspace_data.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';

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
/// creating a project and a checkout per folder. Idempotent.
class ProjectImportService {
  ProjectImportService({
    required this.workspace,
    required this.importedSessionDao,
    required this.ids,
    required this.clock,
  });

  final WorkspaceData workspace;
  final ImportedSessionsData importedSessionDao;
  final IdGenerator ids;
  final Clock clock;

  Future<ImportSummary> importAll(List<DetectedProject> detected) async {
    var summary = const ImportSummary();
    for (final project in detected) {
      summary = summary + await _importOne(project);
    }
    return summary;
  }

  Future<ImportSummary> _importOne(DetectedProject detected) async {
    final all = [...detected.sessions, ...detected.subagentSessions];
    if (all.isEmpty) return const ImportSummary();
    final root = all.first.cwd;
    final itself = [
      DiscoveredRepository(name: _basename(root.path), path: root),
    ];

    var addedProjects = 0;
    var addedRepos = 0;
    Repository? repository;
    final project = _findProjectByRoot(root);
    if (project == null) {
      final created = await workspace.write(
        ProjectCreate(
          projectName: _basename(root.path),
          root: root,
          found: itself,
        ),
      );
      addedProjects = 1;
      addedRepos = created.repositories.length;
      repository = created.repositories.first;
    } else {
      repository = _findRepository(project.id, root);
      if (repository == null) {
        final added = await workspace.write(
          CheckoutsAdd(projectId: project.id, found: itself, orRoot: false),
        );
        addedRepos = added.length;
        repository = added.firstOrNull ?? _findRepository(project.id, root);
      }
    }
    if (repository == null) return const ImportSummary();

    final now = clock.nowUtc();
    var addedSessions = 0;
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
    for (final project in workspace.projects) {
      if (project.root == root) return project;
    }
    return null;
  }

  Repository? _findRepository(String projectId, EnvironmentPath path) {
    for (final repo in workspace.repositoriesOf(projectId)) {
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
