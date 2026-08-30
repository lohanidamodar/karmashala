import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/file_explorer/application/file_explorer_providers.dart';

/// Folders never worth indexing. Walking `node_modules` once costs more than
/// everything else in a repository put together, and nothing in it is a file
/// the user meant to open.
const _skippedDirectories = {
  '.git',
  '.dart_tool',
  '.gradle',
  '.idea',
  '.next',
  '.svelte-kit',
  '.venv',
  '__pycache__',
  'build',
  'dist',
  'node_modules',
  'obj',
  'out',
  'Pods',
  'target',
  'vendor',
};

/// A file in the indexed repository: its path relative to the root (the thing
/// worth searching and showing) and the host path needed to open it.
class IndexedFile {
  const IndexedFile({required this.relativePath, required this.hostPath});

  final String relativePath;
  final String hostPath;

  /// The last segment — what a query usually means.
  String get name {
    final cut = relativePath.lastIndexOf('/');
    return cut < 0 ? relativePath : relativePath.substring(cut + 1);
  }
}

/// Walks a repository once and remembers what it found.
///
/// **Bounded on purpose.** A quick-open index that walks an unbounded tree is a
/// quick-open index that hangs on somebody's home directory: the walk stops at
/// [maxFiles] and [maxDepth], skips the folders above, and yields to the event
/// loop every few hundred entries so a large repository never blocks a frame.
class RepoFileIndex {
  RepoFileIndex({this.maxFiles = 6000, this.maxDepth = 10});

  final int maxFiles;
  final int maxDepth;

  final Map<String, List<IndexedFile>> _cache = {};
  final Map<String, Future<List<IndexedFile>>> _inFlight = {};

  /// What has already been indexed for [root], without starting a walk.
  /// Quick open renders this on the first frame and never waits for the walk.
  List<IndexedFile> cached(String root) => _cache[root] ?? const [];

  bool isIndexed(String root) => _cache.containsKey(root);

  /// Indexes [root], reusing a completed or in-flight walk.
  Future<List<IndexedFile>> index(String root) {
    final done = _cache[root];
    if (done != null) return Future.value(done);
    return _inFlight[root] ??= _walk(
      root,
    ).whenComplete(() => _inFlight.remove(root));
  }

  /// Drops what was learned about [root] so the next query re-walks it.
  void invalidate(String root) {
    _cache.remove(root);
    _inFlight.remove(root);
  }

  Future<List<IndexedFile>> _walk(String root) async {
    final files = <IndexedFile>[];
    final queue = <(Directory, int)>[(Directory(root), 0)];
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root.length
        : root.length + 1;
    var since = 0;

    while (queue.isNotEmpty && files.length < maxFiles) {
      final (directory, depth) = queue.removeAt(0);
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } catch (_) {
        // A folder we cannot read is not an error worth surfacing; a file we
        // cannot see is simply not findable.
        continue;
      }
      for (final entity in entries) {
        final name = entity.path.split(RegExp(r'[\\/]')).last;
        if (name.isEmpty) continue;
        if (entity is Directory) {
          if (_skippedDirectories.contains(name)) continue;
          if (depth + 1 <= maxDepth) queue.add((entity, depth + 1));
          continue;
        }
        if (files.length >= maxFiles) break;
        if (entity.path.length <= prefix) continue;
        files.add(
          IndexedFile(
            relativePath: entity.path.substring(prefix).replaceAll(r'\', '/'),
            hostPath: entity.path,
          ),
        );
      }
      // Give the frame back regularly: a 6000-file repository is several
      // hundred directory listings and the window must stay live throughout.
      if (++since >= 24) {
        since = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }

    _cache[root] = files;
    return files;
  }
}

/// One index for the app, so opening quick open twice does not walk twice.
final repoFileIndexProvider = Provider<RepoFileIndex>((ref) => RepoFileIndex());

/// The root quick open indexes files under: the selected repository's, as a
/// host path. `null` when nothing is selected or the path cannot be resolved.
final quickOpenFileRootProvider = Provider<String?>(
  (ref) => ref.watch(selectedRepoWindowsRootProvider),
);
