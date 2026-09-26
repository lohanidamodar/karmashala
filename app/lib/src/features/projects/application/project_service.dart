import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart'
    show kGitChildEnvironment, kGitRemovedEnvironment;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import '../../workspaces/data/workspace_data.dart';

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

/// What only this machine can do for a project — look at its folders (scan,
/// clone, translate a path between environments) — before the server records
/// what was found, by its own rules: the checkouts a new project gets, what a
/// moved root carries along, what a rescan adds.
class ProjectService {
  ProjectService({
    required this.workspace,
    required this.discovery,
    this.runnerFactory,
    this.translator = const PathTranslator(),
  });

  final WorkspaceData workspace;
  final RepositoryDiscoveryService discovery;
  final CommandRunnerFactory? runnerFactory;
  final PathTranslator translator;

  /// Creates a project rooted at [root] with the Git repositories beneath it.
  /// Discovery failures throw before anything is written.
  Future<ProjectCheckouts> createProjectByDiscovery({
    required String name,
    required EnvironmentPath root,
    int maxDepth = 5,
  }) async => workspace.write(
    ProjectCreate(
      projectName: name,
      root: root,
      found: await discovery.discover(root, maxDepth: maxDepth),
    ),
  );

  /// Where a project with no checkout at all runs: the server records its own
  /// folder (a session runs in a directory; Git is not the point) and this
  /// answers it — or the checkout it already had.
  Future<Repository> recordRootAsCheckout(Project project) async {
    final added = await workspace.write(CheckoutsAdd(projectId: project.id));
    return added.firstOrNull ?? workspace.repositoriesOf(project.id).first;
  }

  /// Creates a project for [target] from a folder picked on the Windows host —
  /// discovery scans there, then the rows are bound to (and translated for) [target].
  Future<ProjectCheckouts> createProjectForEnvironment({
    required String name,
    required String windowsScanPath,
    required ExecutionEnvironment windows,
    required ExecutionEnvironment target,
    String? workspaceId,
    int maxDepth = 5,
  }) async {
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
    return workspace.write(
      ProjectCreate(
        projectName: name,
        root: toTarget(windowsScanPath),
        workspaceId: workspaceId,
        found: [
          for (final d in discovered)
            DiscoveredRepository(name: d.name, path: toTarget(d.path.path)),
        ],
      ),
    );
  }

  /// Creates a project in [target], optionally cloning [gitRepoUrl]. With an
  /// empty [targetPath]: SSH/WSL default to `~/karmashala/<repoName>`, local throws.
  Future<ProjectCheckouts> createProject({
    required String name,
    required ExecutionEnvironment target,
    required String targetPath,
    String? gitRepoUrl,
    String? workspaceId,
    int maxDepth = 5,
  }) async {
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
    return workspace.write(
      ProjectCreate(
        projectName: name,
        root: root,
        workspaceId: workspaceId,
        found: await discovery.discover(root, maxDepth: maxDepth),
      ),
    );
  }

  static String _posixQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  /// Re-runs discovery for an existing [project]; the server records what it
  /// did not have. Returns the newly added rows.
  Future<List<Repository>> rediscover(
    Project project, {
    required ExecutionEnvironment projectEnvironment,
    required ExecutionEnvironment windows,
    int maxDepth = 5,
  }) async {
    final scanRoot = _hostPath(project.root, projectEnvironment, windows);
    final discovered = await discovery.discover(scanRoot, maxDepth: maxDepth);
    return workspace.write(
      CheckoutsAdd(
        projectId: project.id,
        found: _toProject(discovered, projectEnvironment, windows),
      ),
    );
  }

  /// Edits [project]: its name, the checkout its one-click session runs in,
  /// and where its root folder is. A moved root is discovered here before
  /// anything is written, so a folder that is not there fails with nothing
  /// changed; the server carries the checkouts underneath across.
  Future<ProjectUpdated> updateProject(
    Project project, {
    String? name,
    EnvironmentPath? root,
    String? defaultRepositoryId,
    bool clearDefaultRepository = false,
    ExecutionEnvironment? target,
    ExecutionEnvironment? windows,
    int maxDepth = 5,
  }) async {
    final moving = root != null && rootMoves(project.root, root);
    var found = const <DiscoveredRepository>[];
    if (moving) {
      if (target == null || windows == null) {
        throw StateError('Moving a project root needs its environments.');
      }
      final discovered = await discovery.discover(
        _hostPath(root, target, windows),
        maxDepth: maxDepth,
      );
      found = _toProject(discovered, target, windows);
    }
    return workspace.write(
      ProjectUpdate(
        id: project.id,
        projectName: name,
        root: root,
        defaultRepositoryId: defaultRepositoryId,
        clearDefaultRepository: clearDefaultRepository,
        found: found,
      ),
    );
  }

  /// Where [path], in [environment], is scanned from on this host.
  EnvironmentPath _hostPath(
    EnvironmentPath path,
    ExecutionEnvironment environment,
    ExecutionEnvironment windows,
  ) => environment.kind == EnvironmentKind.ssh || environment.id == windows.id
      ? path
      : translator.translate(path, from: environment, to: windows);

  /// What the host scan [found], spelled for [environment].
  List<DiscoveredRepository> _toProject(
    List<DiscoveredRepository> found,
    ExecutionEnvironment environment,
    ExecutionEnvironment windows,
  ) => [
    for (final d in found)
      environment.kind == EnvironmentKind.ssh || environment.id == windows.id
          ? d
          : DiscoveredRepository(
              name: d.name,
              path: translator.translate(
                d.path,
                from: windows,
                to: environment,
              ),
            ),
  ];
}
