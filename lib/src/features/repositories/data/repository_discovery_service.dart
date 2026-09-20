import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:karmashala_git/repositories.dart';

/// Raised when repository discovery cannot proceed (e.g. the root folder does
/// not exist). Carries an actionable message for the UI.
class RepositoryDiscoveryException implements Exception {
  RepositoryDiscoveryException(this.message);
  final String message;
  @override
  String toString() => 'RepositoryDiscoveryException: $message';
}

/// Directory names never worth walking into. Not a correctness filter — a repo
/// inside `node_modules` is somebody else's — but the thing that makes scanning
/// *into* a repository affordable at all.
const _skippedDirectories = {
  'node_modules',
  'build',
  'target',
  'vendor',
  'dist',
  'out',
  'Pods',
  '__pycache__',
};

/// Discovers Git repositories within a folder. Read-only: it inspects the
/// filesystem and runs no process.
abstract interface class RepositoryDiscoveryService {
  /// Returns the Git repositories found under [root], scanning at most
  /// [maxDepth] directory levels below it.
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  });
}

/// [RepositoryDiscoveryService] backed by the local `dart:io` filesystem, so
/// only valid for paths in the local (Windows-native) environment.
class LocalRepositoryDiscoveryService implements RepositoryDiscoveryService {
  const LocalRepositoryDiscoveryService();

  @override
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    final rootDir = Directory(root.path);
    if (!await rootDir.exists()) {
      throw RepositoryDiscoveryException('Folder does not exist: ${root.path}');
    }

    final found = <DiscoveredRepository>[];
    await _scan(rootDir, root.environmentId, 0, maxDepth, found);
    found.sort((a, b) => a.path.path.compareTo(b.path.path));
    return found;
  }

  Future<void> _scan(
    Directory dir,
    String environmentId,
    int depth,
    int maxDepth,
    List<DiscoveredRepository> found,
  ) async {
    if (await _isGitRepository(dir)) {
      found.add(
        DiscoveredRepository(
          name: p.basename(dir.path),
          path: EnvironmentPath(environmentId: environmentId, path: dir.path),
        ),
      );
      // …and keep going. A folder with a `.git` in it is a repository whether or
      // not an ancestor is; stopping here reported a hub of clones as one repo.
    }

    if (depth >= maxDepth) return;

    final List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } on FileSystemException {
      // Unreadable directory (permissions, transient): skip it, don't fail the
      // whole scan.
      return;
    }

    for (final child in children) {
      if (child is! Directory) continue;
      if (FileSystemEntity.isLinkSync(child.path)) continue;
      final name = p.basename(child.path);
      // Skip dot-directories (e.g. .git, .dart_tool) — none are project repos.
      if (name.startsWith('.')) continue;
      if (_skippedDirectories.contains(name)) continue;
      await _scan(child, environmentId, depth + 1, maxDepth, found);
    }
  }

  /// A directory is a Git repository if it contains a `.git` entry — either a
  /// directory (normal clone) or a file (worktree / submodule gitlink).
  Future<bool> _isGitRepository(Directory dir) async {
    final gitPath = p.join(dir.path, '.git');
    return await Directory(gitPath).exists() || await File(gitPath).exists();
  }
}

/// A [RepositoryDiscoveryService] that uses the local filesystem for host
/// paths and a command runner for POSIX paths in WSL and SSH environments.
class EnvironmentAwareRepositoryDiscoveryService
    implements RepositoryDiscoveryService {
  const EnvironmentAwareRepositoryDiscoveryService({
    required this.localDiscovery,
    required this.runnerFactory,
    required this.environments,
  });

  final RepositoryDiscoveryService localDiscovery;
  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environments;

  @override
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    final env = ExecutionEnvironmentResolver(
      environments: environments,
      runners: runnerFactory,
    ).resolveFor(root).environment;
    if (env != null &&
        (env.kind == EnvironmentKind.ssh || env.kind == EnvironmentKind.wsl)) {
      return _discoverPosix(root, env, maxDepth: maxDepth);
    }
    return localDiscovery.discover(root, maxDepth: maxDepth);
  }

  Future<List<DiscoveredRepository>> _discoverPosix(
    EnvironmentPath root,
    ExecutionEnvironment env, {
    int maxDepth = 5,
  }) async {
    final runner = runnerFactory.forEnvironment(env);
    final findDepth = maxDepth < 0 ? 1 : maxDepth + 1;
    final escaped = "'${root.path.replaceAll("'", r"'\''")}'";
    final skipped = _skippedDirectories
        .map((name) => '-name ${_posixQuote(name)}')
        .join(' -o ');
    final prune = r'\( -type d \( ' + skipped + r' \) -prune \) -o';
    final script =
        '''
ROOT=$escaped
if [ ! -d "\$ROOT" ]; then
  echo "Repository root does not exist: \$ROOT" >&2
  exit 2
fi
find "\$ROOT" -maxdepth $findDepth $prune -name .git -print
''';
    final result = await runner.run(
      CommandRequest(executable: 'sh', arguments: ['-c', script]),
    );
    if (!result.ok) {
      final detail = result.stderr.trim();
      throw RepositoryDiscoveryException(
        detail.isEmpty ? 'Could not scan ${root.path} in ${env.name}.' : detail,
      );
    }

    final seen = <String>{};
    final found = <DiscoveredRepository>[];
    for (final line in const LineSplitter().convert(result.stdout)) {
      var trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
        trimmed = trimmed.substring(1, trimmed.length - 1);
      }
      if (trimmed.endsWith('/.git')) {
        trimmed = trimmed.substring(0, trimmed.length - 5);
      }
      final parts = trimmed.split('/');
      if (parts.any(_skippedDirectories.contains)) continue;

      if (seen.add(trimmed)) {
        found.add(
          DiscoveredRepository(
            name: p.posix.basename(trimmed),
            path: EnvironmentPath(
              environmentId: root.environmentId,
              path: trimmed,
            ),
          ),
        );
      }
    }
    found.sort((a, b) => a.path.path.compareTo(b.path.path));
    return found;
  }

  static String _posixQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";
}
