import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/path_translator.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../explorer/application/checkout.dart';
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

/// Helper to parse a repository name from a git URL.
String repoNameFromUrl(String url) {
  var cleaned = url.trim();
  if (cleaned.endsWith('.git')) {
    cleaned = cleaned.substring(0, cleaned.length - 4);
  }
  while (cleaned.endsWith('/')) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }
  final slashIndex = cleaned.lastIndexOf('/');
  final colonIndex = cleaned.lastIndexOf(':');
  final lastSep = slashIndex > colonIndex ? slashIndex : colonIndex;
  if (lastSep != -1 && lastSep < cleaned.length - 1) {
    return cleaned.substring(lastSep + 1);
  }
  return cleaned;
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
    this.runnerFactory,
    this.translator = const PathTranslator(),
  });

  final ProjectDao projectDao;
  final RepositoryDao repositoryDao;
  final RepositoryDiscoveryService discovery;
  final IdGenerator ids;
  final Clock clock;
  final CommandRunnerFactory? runnerFactory;
  final PathTranslator translator;

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

  /// Creates a project for [target] from a folder picked on the Windows host.
  ///
  /// The native folder picker always yields a Windows-accessible path
  /// ([windowsScanPath]) — a drive path or a `\\wsl.localhost\…` UNC — so
  /// discovery scans there, then the project root and each repository are bound
  /// to [target] (translated into the WSL namespace when [target] is WSL).
  Future<ProjectCreationResult> createProjectForEnvironment({
    required String name,
    required String windowsScanPath,
    required ExecutionEnvironment windows,
    required ExecutionEnvironment target,
    String? workspaceId,
    int maxDepth = 5,
  }) async {
    final now = clock.nowUtc();
    final scanRoot = EnvironmentPath(
      environmentId: windows.id,
      path: windowsScanPath,
    );
    // Discover on the Windows-accessible path first (fail before persisting).
    final discovered = await discovery.discover(scanRoot, maxDepth: maxDepth);

    EnvironmentPath toTarget(String winPath) => target.id == windows.id
        ? EnvironmentPath(environmentId: target.id, path: winPath)
        : translator.translate(
            EnvironmentPath(environmentId: windows.id, path: winPath),
            from: windows,
            to: target,
          );

    final project = Project(
      id: ids.newId(),
      name: name,
      root: toTarget(windowsScanPath),
      createdAt: now,
      workspaceId: workspaceId,
    );
    projectDao.insert(project);

    final repositories = <Repository>[];
    for (final d in discovered) {
      final repo = Repository(
        id: ids.newId(),
        projectId: project.id,
        name: d.name,
        path: toTarget(d.path.path),
        createdAt: now,
      );
      repositoryDao.insert(repo);
      repositories.add(repo);
    }
    return ProjectCreationResult(project: project, repositories: repositories);
  }

  /// Creates a project in [target] environment, optionally cloning [gitRepoUrl].
  ///
  /// If [gitRepoUrl] is provided and [targetPath] is empty:
  /// - For SSH/WSL: defaults to `~/karmashala/<repoName>`.
  /// - For Windows/local: throws [RepositoryDiscoveryException] prompting for a destination path.
  Future<ProjectCreationResult> createProject({
    required String name,
    required ExecutionEnvironment target,
    required String targetPath,
    String? gitRepoUrl,
    String? workspaceId,
    int maxDepth = 5,
  }) async {
    final now = clock.nowUtc();
    final url = gitRepoUrl?.trim();
    final hasGit = url != null && url.isNotEmpty;
    var path = targetPath.trim();

    if (hasGit && path.isEmpty) {
      final repoName = repoNameFromUrl(url);
      if (target.kind == EnvironmentKind.ssh ||
          target.kind == EnvironmentKind.wsl) {
        path = '~/karmashala/$repoName';
      } else {
        throw RepositoryDiscoveryException(
          'Please choose a folder path to clone the repository into.',
        );
      }
    } else if (path.isEmpty) {
      throw RepositoryDiscoveryException(
        'Please provide a folder path or a Git repository URL.',
      );
    }

    String resolvedPath = path;

    if (hasGit) {
      if (runnerFactory == null) {
        throw StateError(
          'CommandRunnerFactory is required to clone git repositories.',
        );
      }
      final runner = runnerFactory!.forEnvironment(target);
      if (target.kind == EnvironmentKind.ssh ||
          target.kind == EnvironmentKind.wsl) {
        final targetExpression = path == '~'
            ? r'"$HOME"'
            : path.startsWith('~/')
            ? '${r'"$HOME"'}/${_posixQuote(path.substring(2))}'
            : _posixQuote(path);
        final cloneEscaped = "'${url.replaceAll("'", r"'\''")}'";
        final cloneScript = '''
TARGET=$targetExpression
if [ -d "\$TARGET/.git" ]; then
  echo "EXISTS"
else
  mkdir -p "\$(dirname "\$TARGET")" && git clone $cloneEscaped "\$TARGET"
fi
cd "\$TARGET" && pwd
''';
        final result = await runner.run(
          CommandRequest(
            executable: 'sh',
            arguments: ['-c', cloneScript],
          ),
        );
        if (!result.ok) {
          throw RepositoryDiscoveryException(
            'Failed to clone repository on ${target.name}: ${result.stderr.trim()}',
          );
        }
        final lines = result.stdout.trim().split('\n');
        resolvedPath = lines.last.trim();
      } else {
        final dir = Directory(path);
        final gitDir = Directory(p.join(path, '.git'));
        if (!gitDir.existsSync()) {
          if (!dir.existsSync()) {
            dir.parent.createSync(recursive: true);
          }
          final result = await runner.run(
            CommandRequest(
              executable: 'git',
              arguments: ['clone', url, path],
            ),
          );
          if (!result.ok) {
            throw RepositoryDiscoveryException(
              'Failed to clone repository: ${result.stderr.trim()}',
            );
          }
        }
        resolvedPath = dir.path;
      }
    } else if (target.kind == EnvironmentKind.ssh) {
      if (runnerFactory != null) {
        final runner = runnerFactory!.forEnvironment(target);
        final posixEscaped = "'${path.replaceAll("'", r"'\''")}'";
        final result = await runner.run(
          CommandRequest(
            executable: 'sh',
            arguments: ['-c', 'cd $posixEscaped 2>/dev/null && pwd'],
          ),
        );
        if (!result.ok || result.stdout.trim().isEmpty) {
          throw RepositoryDiscoveryException(
            'Folder does not exist on ${target.name}: $path',
          );
        }
        resolvedPath = result.stdout.trim().split('\n').last.trim();
      }
    }

    final root = EnvironmentPath(
      environmentId: target.id,
      path: resolvedPath,
    );

    final discovered = await discovery.discover(root, maxDepth: maxDepth);

    final project = Project(
      id: ids.newId(),
      name: name,
      root: root,
      createdAt: now,
      workspaceId: workspaceId,
    );
    projectDao.insert(project);

    final repositories = <Repository>[];
    if (discovered.isEmpty) {
      var rootIsRepo = false;
      if (target.kind == EnvironmentKind.ssh) {
        if (runnerFactory != null) {
          final runner = runnerFactory!.forEnvironment(target);
          final check = await runner.run(
            CommandRequest(
              executable: 'sh',
              arguments: [
                '-c',
                'test -e \'${resolvedPath.replaceAll("'", r"'\''")}/.git\'',
              ],
            ),
          );
          rootIsRepo = check.ok;
        }
      } else {
        rootIsRepo =
            Directory(p.join(resolvedPath, '.git')).existsSync() ||
            File(p.join(resolvedPath, '.git')).existsSync();
      }

      if (rootIsRepo) {
        final repo = Repository(
          id: ids.newId(),
          projectId: project.id,
          name: name,
          path: root,
          createdAt: now,
        );
        repositoryDao.insert(repo);
        repositories.add(repo);
      }
    } else {
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
    }

    return ProjectCreationResult(project: project, repositories: repositories);
  }

  static String _posixQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  /// Re-runs discovery for an existing [project] and persists any repositories
  /// not already recorded. Returns the newly added rows.
  Future<List<Repository>> rediscover(
    Project project, {
    required ExecutionEnvironment projectEnvironment,
    required ExecutionEnvironment windows,
    int maxDepth = 5,
  }) async {
    final existing = repositoryDao
        .getByProject(project.id)
        .map((r) => Checkout(r.path))
        .toSet();
    final scanRoot = projectEnvironment.kind == EnvironmentKind.ssh
        ? project.root
        : projectEnvironment.id == windows.id
        ? project.root
        : translator.translate(
            project.root,
            from: projectEnvironment,
            to: windows,
          );
    final discovered = await discovery.discover(scanRoot, maxDepth: maxDepth);
    EnvironmentPath toProject(EnvironmentPath hostPath) =>
        projectEnvironment.kind == EnvironmentKind.ssh ||
        projectEnvironment.id == windows.id
        ? hostPath
        : translator.translate(
            hostPath,
            from: windows,
            to: projectEnvironment,
          );
    final now = clock.nowUtc();
    final added = <Repository>[];
    for (final d in discovered) {
      final path = toProject(d.path);
      if (existing.contains(Checkout(path))) continue;
      final repo = Repository(
        id: ids.newId(),
        projectId: project.id,
        name: d.name,
        path: path,
        createdAt: now,
      );
      repositoryDao.insert(repo);
      added.add(repo);
    }
    return added;
  }
}
