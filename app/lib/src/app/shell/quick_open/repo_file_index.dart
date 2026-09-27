import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show CheckoutTouchCause;
import '../../../features/editor/application/code_editor_providers.dart';
import '../../../features/git/data/git_data.dart';
import '../../../features/checkpoints/application/checkpoint_providers.dart';
import '../../../features/file_explorer/application/file_explorer_providers.dart';
import '../../../features/sessions/application/session_ui_providers.dart';

/// Folders never worth indexing. Walking `node_modules` once costs more than
/// everything else in a repository put together.
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

  /// The walk was abandoned — the dialog closed or the root changed under it.
  final bool cancelled;

  final Duration elapsed;
}

/// Walks a repository and keeps what it found current, bounded by [maxFiles],
/// [maxDepth] and [maxDuration]; a [DirectoryChangeWatcher] only marks it stale.
class RepoFileIndex {
  RepoFileIndex({
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

  final int maxFiles;
  final int maxDepth;

  /// Directories the walk may visit. The bound the old walk was missing.
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

  final Map<String, _Indexed> _entries = {};
  final Map<String, Future<List<IndexedFile>>> _inFlight = {};
  final Map<String, int> _generation = {};

  /// Roots touched while a walk was running, against that walk's generation: a
  /// change during walk *n* says nothing about walk *n+1*.
  final Map<String, int> _dirtyAt = {};

  /// Watched roots, least recently indexed first.
  final ListQueue<String> _watchOrder = ListQueue();

  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  var _disposed = false;

  /// Emits a root whenever what is known about it changed. Quick open listens
  /// while it is open, so a file created behind the dialog shows up in it.
  Stream<String> get changes => _changes.stream;

  /// How this index learns about changes, for a diagnostic or a test.
  DirectoryWatchMode get watchMode => _watcher.mode;

  /// What has already been indexed for [root], without starting a walk.
  /// Quick open renders this on the first frame and never waits for the walk.
  List<IndexedFile> cached(String root) => _entries[root]?.files ?? const [];

  bool isIndexed(String root) => _entries.containsKey(root);

  /// What the last completed walk of [root] cost, or `null` if never walked.
  RepoIndexStats? statsFor(String root) => _entries[root]?.stats;

  /// Whether [root] can be answered from cache without walking again.
  bool isFresh(String root) {
    final entry = _entries[root];
    if (entry == null || entry.stale) return false;
    return _now().difference(entry.walkedAt) < refreshInterval;
  }

  /// Indexes [root] if what is cached is not fresh, reusing an in-flight walk.
  /// Cheap on every keystroke: a fresh root never touches the filesystem.
  Future<List<IndexedFile>> index(String root) {
    if (_disposed) return Future.value(cached(root));
    _ensureWatch(root);
    if (isFresh(root)) return Future.value(cached(root));
    final running = _inFlight[root];
    if (running != null) return running;

    final generation = (_generation[root] ?? 0) + 1;
    _generation[root] = generation;
    late final Future<List<IndexedFile>> walk;
    walk = _walk(root, generation).whenComplete(() {
      if (identical(_inFlight[root], walk)) _inFlight.remove(root);
    });
    _inFlight[root] = walk;
    return walk;
  }

  /// Walks [root] again whatever the cache says, abandoning a walk in progress.
  Future<List<IndexedFile>> refresh(String root) {
    touch(root);
    cancel(root);
    return index(root);
  }

  /// Marks [root] stale without throwing away what is known about it.
  /// [invalidate] is the blunter version, for an answer wrong rather than old.
  void touch(String root) {
    if (_inFlight.containsKey(root)) _dirtyAt[root] = _generation[root]!;
    final entry = _entries[root];
    if (entry == null || entry.stale) return;
    entry.stale = true;
    _emit(root);
  }

  /// Marks every known root stale. What a signal that names no repository —
  /// a session revision, an agent turn ending — can honestly do.
  void touchAll() {
    for (final root in {..._entries.keys, ..._inFlight.keys}) {
      touch(root);
    }
  }

  /// Drops what was learned about [root] so the next query re-walks it.
  void invalidate(String root) {
    _entries.remove(root);
    cancel(root);
    _emit(root);
  }

  void invalidateAll() {
    for (final root in {..._entries.keys, ..._inFlight.keys}) {
      invalidate(root);
    }
  }

  /// Abandons any walk of [root] in progress. What it had already found is kept
  /// as a stale partial when nothing better is cached.
  void cancel(String root) {
    _generation[root] = (_generation[root] ?? 0) + 1;
    _inFlight.remove(root);
  }

  void cancelAll() {
    for (final root in _inFlight.keys.toList()) {
      cancel(root);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll();
    _watcher.dispose();
    _watchOrder.clear();
    _changes.close();
  }

  void _emit(String root) {
    if (_disposed || _changes.isClosed) return;
    _changes.add(root);
  }

  void _ensureWatch(String root) {
    // A share is walked again when stale and never watched: a recursive watch
    // held on `\\wsl.localhost` is background access on the path Windows
    // antivirus scans (docs/windows-antivirus.md).
    if (root.startsWith(r'\\') || root.startsWith('//')) return;
    _watchOrder.remove(root);
    _watchOrder.addLast(root);
    if (!_watcher.isWatching(root)) {
      _watcher.watch(
        root,
        () => touch(root),
        ignore: (path) => _isSkippedPath(root, path),
      );
    }
    while (_watchOrder.length > maxWatchedRoots) {
      _watcher.unwatch(_watchOrder.removeFirst());
    }
  }

  /// Whether a changed path sits under one of the folders the walk skips — the
  /// difference between a free watch and one that re-walks on every build.
  bool _isSkippedPath(String root, String path) {
    if (!path.startsWith(root)) return false;
    for (final segment in _segments(path.substring(root.length))) {
      if (_skippedDirectories.contains(segment)) return true;
    }
    return false;
  }

  static Iterable<String> _segments(String path) sync* {
    var start = 0;
    for (var i = 0; i < path.length; i++) {
      if (_isSeparator(path.codeUnitAt(i))) {
        if (i > start) yield path.substring(start, i);
        start = i + 1;
      }
    }
    if (start < path.length) yield path.substring(start);
  }

  static bool _isSeparator(int code) => code == 0x2F || code == 0x5C;

  /// The last path segment, without the `RegExp` and list per entry that
  /// `path.split(RegExp(r'[\\/]')).last` allocated.
  static String _lastSegment(String path) {
    for (var i = path.length - 1; i >= 0; i--) {
      if (_isSeparator(path.codeUnitAt(i))) return path.substring(i + 1);
    }
    return path;
  }

  Future<List<IndexedFile>> _walk(String root, int generation) async {
    final elapsed = Stopwatch()..start();
    final sinceYield = Stopwatch()..start();
    final files = <IndexedFile>[];
    final queue = ListQueue<(Directory, int)>()..add((Directory(root), 0));
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root.length
        : root.length + 1;
    var directories = 0;
    var truncated = false;

    while (queue.isNotEmpty) {
      if (_generation[root] != generation) {
        return _keepPartial(
          root,
          generation,
          files,
          directories,
          elapsed.elapsed,
        );
      }
      if (files.length >= maxFiles ||
          directories >= maxDirectories ||
          elapsed.elapsed >= maxDuration) {
        truncated = true;
        break;
      }
      final (directory, depth) = queue.removeFirst();
      directories++;
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } catch (_) {
        // A folder we cannot read is not an error worth surfacing; a file we
        // cannot see is simply not findable.
        continue;
      }
      // Deterministic truncation: which files survive a bound must not depend
      // on the order the filesystem happened to hand them back.
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        // With `followLinks: false` every symlink and junction arrives as a
        // `Link`; skipping them is what stops a cycle, or a scan of `C:\`.
        if (entity is Link) continue;
        final name = _lastSegment(entity.path);
        if (name.isEmpty) continue;
        if (entity is Directory) {
          if (_skippedDirectories.contains(name)) continue;
          if (depth + 1 <= maxDepth) queue.add((entity, depth + 1));
          continue;
        }
        if (files.length >= maxFiles) {
          truncated = true;
          break;
        }
        if (entity.path.length <= prefix) continue;
        files.add(
          IndexedFile(
            relativePath: entity.path.substring(prefix).replaceAll(r'\', '/'),
            hostPath: entity.path,
          ),
        );
      }
      // A time budget, not a directory count: a count pays for a hop after
      // twenty-four instant directories and skips one that took eighty ms.
      if (sinceYield.elapsedMilliseconds >= _yieldBudgetMs) {
        sinceYield.reset();
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (_generation[root] != generation) {
      return _keepPartial(
        root,
        generation,
        files,
        directories,
        elapsed.elapsed,
      );
    }
    final entry = _Indexed(
      files: files,
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
    _emit(root);
    return files;
  }

  /// Keeps what an abandoned walk found, but only when nothing better is
  /// cached: a partial list must never overwrite a complete one.
  List<IndexedFile> _keepPartial(
    String root,
    int generation,
    List<IndexedFile> files,
    int directories,
    Duration elapsed,
  ) {
    if (_dirtyAt[root] == generation) _dirtyAt.remove(root);
    final existing = _entries[root];
    if (existing != null) return existing.files;
    _entries[root] = _Indexed(
      files: files,
      stats: RepoIndexStats(
        files: files.length,
        directoriesVisited: directories,
        truncated: true,
        cancelled: true,
        elapsed: elapsed,
      ),
      walkedAt: _now(),
    )..stale = true;
    return files;
  }
}

/// Roughly half a 120 Hz frame: long enough that the yield is not most of the
/// cost, short enough that no single stretch of walking drops one.
const _yieldBudgetMs = 4;

class _Indexed {
  _Indexed({required this.files, required this.stats, required this.walkedAt});

  final List<IndexedFile> files;
  final RepoIndexStats stats;
  final DateTime walkedAt;
  bool stale = false;
}

/// One index for the app, so opening quick open twice does not walk twice. The
/// revisions listened to build to a constant, so no test drags in a database.
final repoFileIndexProvider = Provider<RepoFileIndex>((ref) {
  final index = RepoFileIndex();
  ref.onDispose(index.dispose);
  ref.listen(sessionsRevisionProvider, (_, _) => index.touchAll());
  ref.listen(checkpointsRevisionProvider, (_, _) => index.touchAll());
  // A write the server made, or a worktree it made or removed: the one change
  // the OS watcher cannot see is a directory appearing or going.
  final touches = ref.watch(gitDataProvider).touches.listen((touched) {
    final root = ref.read(editorActionsProvider).windowsPathFor(
      touched.directory,
    );
    if (root == null) return;
    if (touched.cause == CheckoutTouchCause.worktree) {
      index.invalidate(root);
    } else {
      index.touch(root);
    }
  });
  ref.onDispose(touches.cancel);
  return index;
});

/// The root quick open indexes files under: the selected repository's, as a
/// host path. `null` when nothing is selected or the path cannot be resolved.
final quickOpenFileRootProvider = Provider<String?>(
  (ref) => ref.watch(selectedRepoWindowsRootProvider),
);
