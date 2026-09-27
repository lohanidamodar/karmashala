import 'dart:async';
import 'dart:collection';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart' show DirectoryChangeWatcher;

import 'file_space.dart';
import 'file_values.dart';

/// Folders never worth indexing. Walking `node_modules` once costs more than
/// everything else in a repository put together.
const Set<String> skippedIndexDirectories = {
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

/// What one walk of a checkout found: every file's path relative to the root,
/// `/`-separated, and whether a bound stopped it. What `files.index` answers.
class RepoFiles {
  const RepoFiles({
    required this.files,
    required this.separator,
    this.truncated = false,
  });

  static const RepoFiles none = RepoFiles(files: [], separator: '/');

  /// Relative to the root, always `/`-separated.
  final List<String> files;

  /// How the root's own environment separates a path, so a relative path
  /// can be put back on the root as that environment spells it.
  final String separator;

  /// A bound stopped the walk, so the tree holds files this list does not.
  final bool truncated;

  /// [relative] under [root], in [root]'s own spelling.
  EnvironmentPath pathOf(EnvironmentPath root, String relative) {
    final base = root.path.endsWith(separator)
        ? root.path.substring(0, root.path.length - 1)
        : root.path;
    return EnvironmentPath(
      environmentId: root.environmentId,
      path: '$base$separator${relative.replaceAll('/', separator)}',
    );
  }

  Map<String, Object?> toJson() => {
    'files': files,
    'separator': separator,
    if (truncated) 'truncated': true,
  };

  static RepoFiles fromJson(Map<String, Object?> json) => RepoFiles(
    files: (json['files']! as List).cast<String>(),
    separator: json['separator'] as String? ?? '/',
    truncated: json['truncated'] == true,
  );
}

/// What one walk cost and whether it saw the whole tree. Exposed because "the
/// index is bounded" is only a useful promise if something can check it.
class RepoIndexStats {
  const RepoIndexStats({
    required this.files,
    required this.directoriesVisited,
    required this.truncated,
    required this.cancelled,
    required this.elapsed,
  });

  final int files;
  final int directoriesVisited;

  /// A bound stopped the walk, so the tree holds files this index does not.
  final bool truncated;

  /// The walk was abandoned — the root was dropped under it.
  final bool cancelled;

  final Duration elapsed;
}

/// **Quick Open's index, kept by the server** (slice 3c): walks a checkout
/// wherever it lives — this machine, a WSL distribution over its share, an
/// SSH host over SFTP — bounded by [maxFiles], [maxDepth], [maxDirectories]
/// and [maxDuration], and keeps what it found until told otherwise. A
/// [DirectoryChangeWatcher] on a root this machine can watch, a write the
/// server made or an agent's turn ending there ([touch]) only marks it
/// stale; the next ask walks again.
class RepoFileIndex {
  RepoFileIndex({
    required this.spaces,
    this.maxFiles = 6000,
    this.maxDepth = 10,
    this.maxDirectories = 6000,
    this.maxDuration = const Duration(seconds: 5),
    this.refreshInterval = const Duration(seconds: 30),
    this.maxWatchedRoots = 8,
    DirectoryChangeWatcher? watcher,
    DateTime Function()? now,
  }) : _watcher = watcher ?? DirectoryChangeWatcher(),
       _now = now ?? DateTime.now;

  /// The space a root's environment is read through; null for one the
  /// server cannot reach.
  final FileSpace? Function(String environmentId) spaces;
  final int maxFiles;
  final int maxDepth;

  /// Directories the walk may visit.
  final int maxDirectories;

  /// A last-resort valve for a tree that is slow rather than large. The count
  /// bounds are the deterministic ones that normally stop a walk.
  final Duration maxDuration;

  /// How long a completed walk is trusted with no other signal — the whole
  /// story where there is no recursive watch, a backstop where there is.
  final Duration refreshInterval;

  /// Watches are an OS resource, so the number of roots holding one is capped
  /// and the least recently indexed is dropped first.
  final int maxWatchedRoots;

  final DirectoryChangeWatcher _watcher;
  final DateTime Function() _now;

  final Map<EnvironmentPath, _Indexed> _entries = {};
  final Map<EnvironmentPath, Future<RepoFiles>> _inFlight = {};
  final Map<EnvironmentPath, int> _generation = {};

  /// Roots touched while a walk was running, against that walk's generation:
  /// a change during walk *n* says nothing about walk *n+1*.
  final Map<EnvironmentPath, int> _dirtyAt = {};

  /// Watched roots (by their host spelling), least recently indexed first.
  final ListQueue<String> _watchOrder = ListQueue();

  var _disposed = false;

  /// What has already been indexed for [root], without starting a walk.
  RepoFiles cached(EnvironmentPath root) =>
      _entries[root]?.files ?? RepoFiles.none;

  bool isIndexed(EnvironmentPath root) => _entries.containsKey(root);

  /// What the last completed walk of [root] cost, or `null` if never walked.
  RepoIndexStats? statsFor(EnvironmentPath root) => _entries[root]?.stats;

  /// Whether [root] can be answered from cache without walking again.
  bool isFresh(EnvironmentPath root) {
    final entry = _entries[root];
    if (entry == null || entry.stale) return false;
    return _now().difference(entry.walkedAt) < refreshInterval;
  }

  /// Indexes [root] if what is cached is not fresh, reusing an in-flight walk.
  /// Cheap on every ask: a fresh root never touches the filesystem.
  Future<RepoFiles> index(EnvironmentPath root) {
    if (_disposed) return Future.value(cached(root));
    final space = spaces(root.environmentId);
    if (space == null) {
      return Future.error(
        FileSpaceException('this server cannot reach "${root.environmentId}"'),
      );
    }
    _ensureWatch(root, space);
    if (isFresh(root)) return Future.value(cached(root));
    final running = _inFlight[root];
    if (running != null) return running;

    final generation = (_generation[root] ?? 0) + 1;
    _generation[root] = generation;
    late final Future<RepoFiles> walk;
    walk = _walk(root, space, generation).whenComplete(() {
      if (identical(_inFlight[root], walk)) _inFlight.remove(root);
    });
    _inFlight[root] = walk;
    return walk;
  }

  /// Marks [root] stale without throwing away what is known about it.
  void touch(EnvironmentPath root) {
    if (_inFlight.containsKey(root)) _dirtyAt[root] = _generation[root]!;
    _entries[root]?.stale = true;
  }

  /// Marks every root at or under [path] stale — what a touch of a checkout
  /// or a folder inside one can honestly say.
  void touchUnder(EnvironmentPath path) {
    for (final root in {..._entries.keys, ..._inFlight.keys}) {
      if (root.environmentId != path.environmentId) continue;
      if (_contains(root.path, path.path) || _contains(path.path, root.path)) {
        touch(root);
      }
    }
  }

  static bool _contains(String outer, String inner) {
    final a = outer.replaceAll(r'\', '/');
    final b = inner.replaceAll(r'\', '/');
    return b == a || b.startsWith(a.endsWith('/') ? a : '$a/');
  }

  /// Drops what was learned about [root] so the next ask re-walks it.
  void invalidate(EnvironmentPath root) {
    _entries.remove(root);
    _generation[root] = (_generation[root] ?? 0) + 1;
    _inFlight.remove(root);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final root in _inFlight.keys.toList()) {
      invalidate(root);
    }
    _watcher.dispose();
    _watchOrder.clear();
  }

  void _ensureWatch(EnvironmentPath root, FileSpace space) {
    final host = space.hostPathOf(root);
    // A share is walked again when stale and never watched: a recursive watch
    // held on `\\wsl.localhost` is background access on the path Windows
    // antivirus scans (docs/windows-antivirus.md). SFTP has no watch at all.
    if (host == null || host.startsWith(r'\\') || host.startsWith('//')) {
      return;
    }
    _watchOrder.remove(host);
    _watchOrder.addLast(host);
    if (!_watcher.isWatching(host)) {
      _watcher.watch(
        host,
        () => touch(root),
        ignore: (path) => _isSkippedPath(host, path),
      );
    }
    while (_watchOrder.length > maxWatchedRoots) {
      _watcher.unwatch(_watchOrder.removeFirst());
    }
  }

  /// Whether a changed path sits under one of the folders the walk skips — the
  /// difference between a free watch and one that re-walks on every build.
  static bool _isSkippedPath(String root, String path) {
    if (!path.startsWith(root)) return false;
    for (final segment in path.substring(root.length).split(RegExp(r'[\\/]'))) {
      if (skippedIndexDirectories.contains(segment)) return true;
    }
    return false;
  }

  Future<RepoFiles> _walk(
    EnvironmentPath root,
    FileSpace space,
    int generation,
  ) async {
    final elapsed = Stopwatch()..start();
    final separator = space.pathContext.separator;
    final files = <String>[];
    final queue = ListQueue<(EnvironmentPath, String, int)>()
      ..add((root, '', 0));
    var directories = 0;
    var truncated = false;

    while (queue.isNotEmpty) {
      if (_generation[root] != generation) {
        return _keepPartial(root, separator, files, directories, elapsed);
      }
      if (files.length >= maxFiles ||
          directories >= maxDirectories ||
          elapsed.elapsed >= maxDuration) {
        truncated = true;
        break;
      }
      final (directory, relative, depth) = queue.removeFirst();
      directories++;
      List<FileEntry> entries;
      try {
        entries = await space.list(directory, details: false);
      } on Object {
        // A folder we cannot read is not an error worth surfacing; a file we
        // cannot see is simply not findable.
        continue;
      }
      // Deterministic truncation: which files survive a bound must not depend
      // on the order the filesystem happened to hand them back.
      entries.sort((a, b) => a.name.compareTo(b.name));
      for (final entry in entries) {
        // Every symlink and junction is skipped: that is what stops a cycle,
        // or a walk of `C:\`.
        if (entry.kind == FileEntryKind.symlink || entry.name.isEmpty) {
          continue;
        }
        final path = relative.isEmpty ? entry.name : '$relative/${entry.name}';
        if (entry.isDirectory) {
          if (skippedIndexDirectories.contains(entry.name)) continue;
          if (depth + 1 <= maxDepth) queue.add((entry.path, path, depth + 1));
          continue;
        }
        if (files.length >= maxFiles) {
          truncated = true;
          break;
        }
        files.add(path);
      }
    }

    if (_generation[root] != generation) {
      return _keepPartial(root, separator, files, directories, elapsed);
    }
    final found = RepoFiles(
      files: List.unmodifiable(files),
      separator: separator,
      truncated: truncated,
    );
    final entry = _Indexed(
      files: found,
      stats: RepoIndexStats(
        files: files.length,
        directoriesVisited: directories,
        truncated: truncated,
        cancelled: false,
        elapsed: elapsed.elapsed,
      ),
      walkedAt: _now(),
    );
    // Something moved under us while *this* walk was reading. Publish it — a
    // nearly-right list beats an empty one — but do not let it look fresh.
    entry.stale = _dirtyAt.remove(root) == generation;
    _entries[root] = entry;
    return found;
  }

  /// Keeps what an abandoned walk found, but only when nothing better is
  /// cached: a partial list must never overwrite a complete one.
  RepoFiles _keepPartial(
    EnvironmentPath root,
    String separator,
    List<String> files,
    int directories,
    Stopwatch elapsed,
  ) {
    _dirtyAt.remove(root);
    final existing = _entries[root];
    if (existing != null) return existing.files;
    final partial = RepoFiles(
      files: List.unmodifiable(files),
      separator: separator,
      truncated: true,
    );
    _entries[root] = _Indexed(
      files: partial,
      stats: RepoIndexStats(
        files: files.length,
        directoriesVisited: directories,
        truncated: true,
        cancelled: true,
        elapsed: elapsed.elapsed,
      ),
      walkedAt: _now(),
    )..stale = true;
    return partial;
  }
}

class _Indexed {
  _Indexed({required this.files, required this.stats, required this.walkedAt});

  final RepoFiles files;
  final RepoIndexStats stats;
  final DateTime walkedAt;
  bool stale = false;
}
