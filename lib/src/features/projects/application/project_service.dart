import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import '../../explorer/application/checkout.dart';
import '../../repositories/data/repository_discovery_service.dart';
import '../../repositories/data/repository_dao.dart';
import 'package:karmashala_git/git.dart'
    show kGitChildEnvironment, kGitRemovedEnvironment;
import 'package:karmashala_git/repositories.dart';
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

  /// Creates a project rooted at [root], discovers Git repositories beneath it
  /// and persists everything. Discovery failures throw before any row is written.
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
    if (repositories.isEmpty) {
      repositories.add(recordRootAsCheckout(project, now: now));
    }

    return ProjectCreationResult(project: project, repositories: repositories);
  }

  /// The project's own folder as the place its sessions run. **Git is not the
  /// point**: Claude Code, Codex and Antigravity all start in a plain
  /// directory, and a project with no checkout row could not be given a
  /// session at all — "this project has no Git repositories to run in" was the
  /// whole of what the New Session dialog could say about a folder that simply
  /// was not a clone.
  ///
  /// Public because discovery is not the only thing that asks: a project
  /// recorded before this was true has no checkout at all, and the surface
  /// that wants to start a session there asks the same question.
  Repository recordRootAsCheckout(Project project, {DateTime? now}) {
    final repo = Repository(
      id: ids.newId(),
      projectId: project.id,
      name: project.name,
      path: project.root,
      createdAt: now ?? clock.nowUtc(),
    );
    repositoryDao.insert(repo);
    return repo;
  }

  /// Creates a project for [target] from a folder picked on the Windows host —
  /// discovery scans there, then the rows are bound to (and translated for) [target].
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
    if (repositories.isEmpty) {
      repositories.add(recordRootAsCheckout(project, now: now));
    }
    return ProjectCreationResult(project: project, repositories: repositories);
  }

  /// Creates a project in [target], optionally cloning [gitRepoUrl]. With an
  /// empty [targetPath]: SSH/WSL default to `~/karmashala/<repoName>`, local throws.
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
        final cloneScript =
            '''
TARGET=$targetExpression
if [ -d "\$TARGET/.git" ]; then
  echo "EXISTS"
else
  mkdir -p "\$(dirname "\$TARGET")" && git clone $cloneEscaped "\$TARGET"
fi
cd "\$TARGET" && pwd
''';
        final result = await runner.run(
          CommandRequest(executable: 'sh', arguments: ['-c', cloneScript]),
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
              environment: kGitChildEnvironment,
              removedEnvironment: kGitRemovedEnvironment,
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

    final root = EnvironmentPath(environmentId: target.id, path: resolvedPath);

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
      // The folder itself, whether or not it is a clone: nothing here needs a
      // `.git` to be checked for — a session runs in a directory. The probe
      // this replaces cost an SSH round trip to decide the same thing.
      repositories.add(recordRootAsCheckout(project, now: now));
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
        : translator.translate(hostPath, from: windows, to: projectEnvironment);
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
    // A project that still has nowhere to run gets its own folder, which is
    // what a rescan of a plain directory is asking for. Old projects, made
    // before a folder was enough, are repaired by the same rescan.
    if (existing.isEmpty && added.isEmpty) {
      added.add(recordRootAsCheckout(project, now: now));
    }
    return added;
  }
}

/// What editing a project did. [rebased] and [leftBehind] are only ever
/// non-empty when the root moved.
class ProjectUpdateResult {
  const ProjectUpdateResult({
    required this.project,
    this.rebased = const [],
    this.leftBehind = const [],
    this.discovered = const [],
  });

  final Project project;

  /// Checkouts whose recorded path was rewritten under the new root — the same
  /// rows, keeping their ids, so every session that references one still does.
  final List<Repository> rebased;

  /// Checkouts that were not under the old root. Nothing here knows where they
  /// went, so they are reported rather than guessed at.
  final List<Repository> leftBehind;

  /// Checkouts found under the new root that the project did not have.
  final List<Repository> discovered;
}

/// Editing an existing project: its name, the checkout its one-click session
/// runs in, and — the part with teeth — where its root folder is.
extension ProjectEditing on ProjectService {
  /// Applies the named changes to [project]. A moved root is discovered before
  /// anything is written, so a folder that is not there fails with nothing
  /// changed; the checkouts underneath keep their ids (§20), because that is
  /// what every session, worktree and setting references.
  Future<ProjectUpdateResult> updateProject(
    Project project, {
    String? name,
    EnvironmentPath? root,
    String? defaultRepositoryId,
    bool clearDefaultRepository = false,
    ExecutionEnvironment? target,
    ExecutionEnvironment? windows,
    int maxDepth = 5,
  }) async {
    final newName = name?.trim();
    if (newName != null && newName.isEmpty) {
      throw RepositoryDiscoveryException('A project needs a name.');
    }

    final moving =
        root != null &&
        !(root.environmentId == project.root.environmentId &&
            samePath(root.path, project.root.path));

    var discovered = const <DiscoveredRepository>[];
    if (moving) {
      if (target == null || windows == null) {
        throw StateError('Moving a project root needs its environments.');
      }
      final scanRoot =
          target.kind == EnvironmentKind.ssh || target.id == windows.id
          ? root
          : translator.translate(root, from: target, to: windows);
      discovered = await discovery.discover(scanRoot, maxDepth: maxDepth);
    }

    final rebased = <Repository>[];
    final leftBehind = <Repository>[];
    if (moving) {
      for (final repository in repositoryDao.getByProject(project.id)) {
        final relative = _relativeUnder(project.root, repository.path);
        if (relative == null) {
          leftBehind.add(repository);
          continue;
        }
        final moved = repository.copyWith(path: _underRoot(root, relative));
        repositoryDao.update(moved);
        rebased.add(moved);
      }
    }

    final added = <Repository>[];
    if (moving) {
      final known = {
        for (final repository in [...rebased, ...leftBehind])
          Checkout(repository.path),
      };
      final host = windows!;
      final destination = target!;
      EnvironmentPath toProject(EnvironmentPath hostPath) =>
          destination.kind == EnvironmentKind.ssh || destination.id == host.id
          ? hostPath
          : translator.translate(hostPath, from: host, to: destination);
      final now = clock.nowUtc();
      for (final found in discovered) {
        final path = toProject(found.path);
        if (!known.add(Checkout(path))) continue;
        final repository = Repository(
          id: ids.newId(),
          projectId: project.id,
          name: found.name,
          path: path,
          createdAt: now,
        );
        repositoryDao.insert(repository);
        added.add(repository);
      }
    }

    // A default that no longer names one of this project's checkouts is not an
    // error — it falls back to the picker's first row, which is the rule for a
    // project that never chose.
    final requested = clearDefaultRepository
        ? null
        : (defaultRepositoryId ?? project.defaultRepositoryId);
    final owned = repositoryDao
        .getByProject(project.id)
        .any((repository) => repository.id == requested);

    final updated = Project(
      id: project.id,
      name: newName ?? project.name,
      root: root ?? project.root,
      createdAt: project.createdAt,
      workspaceId: project.workspaceId,
      defaultRepositoryId: owned ? requested : null,
    );
    projectDao.update(updated);

    return ProjectUpdateResult(
      project: updated,
      rebased: rebased,
      leftBehind: leftBehind,
      discovered: added,
    );
  }
}

/// [child] written relative to [root] using paths alone, so a root that also
/// changes environment still carries its checkouts across. `''` when they are
/// the same folder, null when [child] is not underneath.
String? _relativeUnder(EnvironmentPath root, EnvironmentPath child) {
  if (root.environmentId != child.environmentId) return null;
  final parent = canonicalPathKey(root.path);
  final under = canonicalPathKey(child.path);
  if (under == parent) return '';
  if (!under.startsWith('$parent/')) return null;
  return child.path.replaceAll(r'\', '/').substring(parent.length + 1);
}

/// [relative] joined onto [root] in the spelling [root] is written in — a
/// Windows root keeps backslashes, a POSIX one keeps forward slashes.
EnvironmentPath _underRoot(EnvironmentPath root, String relative) {
  if (relative.isEmpty) return root;
  final windowsStyle =
      RegExp(r'^[A-Za-z]:').hasMatch(root.path) || root.path.startsWith(r'\\');
  final base = root.path.replaceAll(RegExp(r'[\\/]+$'), '');
  final tail = windowsStyle ? relative.replaceAll('/', r'\') : relative;
  return EnvironmentPath(
    environmentId: root.environmentId,
    path: windowsStyle ? '$base\\$tail' : '$base/$tail',
  );
}
