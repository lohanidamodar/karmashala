import 'dart:io';

import 'package:path/path.dart' as p;

import '../../environments/domain/environment_path.dart';
import '../domain/discovered_repository.dart';

/// Raised when repository discovery cannot proceed (e.g. the root folder does
/// not exist). Carries an actionable message for the UI.
class RepositoryDiscoveryException implements Exception {
  RepositoryDiscoveryException(this.message);
  final String message;
  @override
  String toString() => 'RepositoryDiscoveryException: $message';
}

/// Discovers Git repositories within a folder.
///
/// Read-only: it inspects the filesystem only. It does **not** run `git` or any
/// other process (that is introduced behind `CommandRunner` in Loop 3).
abstract interface class RepositoryDiscoveryService {
  /// Returns the Git repositories found under [root], scanning at most
  /// [maxDepth] directory levels below it.
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  });
}

/// [RepositoryDiscoveryService] backed by the local `dart:io` filesystem.
///
/// Only valid for paths in the local (Windows-native) environment, since it
/// reads the host filesystem directly.
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
      // Do not descend into a repository (nested checkouts are handled by Git).
      return;
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
