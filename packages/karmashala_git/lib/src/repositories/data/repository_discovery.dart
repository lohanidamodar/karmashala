import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import '../domain/discovered_repository.dart';

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
const Set<String> kSkippedDiscoveryDirectories = {
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
/// only valid for paths on the machine this process runs on — the desktop's
/// own disk, or a session host's.
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
      if (kSkippedDiscoveryDirectories.contains(name)) continue;
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
