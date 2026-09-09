import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/directory_change_watcher.dart';
import '../../../features/checkpoints/application/checkpoint_providers.dart';
import '../../../features/file_explorer/application/file_explorer_providers.dart';
import '../../../features/sessions/application/session_ui_providers.dart';

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

/// Walks a repository and keeps what it found current.
///
/// **Bounded on purpose.** A quick-open index that walks an unbounded tree is a
/// quick-open index that hangs on somebody's home directory. Every walk stops
/// at [maxFiles], [maxDirectories], [maxDepth] and [maxDuration], skips the
/// folders above and every symlink, and yields to the event loop on a time
/// budget so a large repository never blocks a frame.
///
/// The file bound alone was not enough. A tree of twenty thousand empty
/// directories trips none of it — there are no files to count — and the walk
/// used to grind through all of them.
///
/// **Fresh on purpose, too.** The index used to be walked once per root and
/// then trusted for the lifetime of the process, which in an ADE means files an
/// agent wrote a minute ago are not findable and files it deleted still are.
/// Now a cached root is only trusted for [refreshInterval], and a
/// [DirectoryChangeWatcher] marks it stale the moment anything under it moves.
///
/// Staleness never walks by itself. Marking a root stale is free; the re-walk
/// happens the next time somebody calls [index], which is to say the next time
/// quick open is actually open and looking. A repository nobody is searching
/// costs one OS watch handle and nothing else.
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

  /// A last-resort valve for a tree that is slow rather than large — a network
  /// share, a cold spinning disk. The count bounds above are the ones that
  /// normally stop a walk, and they are the deterministic ones; this is here so
  /// that a pathological filesystem cannot hold the UI isolate for a minute.
  final Duration maxDuration;

  /// How long a completed walk is trusted with no other signal. This is the
  /// whole freshness story on a platform with no recursive watch, and a
  /// backstop everywhere else for the changes a watch can miss (buffer
  /// overflow, network drives, a root replaced wholesale).
  final Duration refreshInterval;

  /// Watches are an OS resource, so the number of roots holding one is capped
  /// and the least recently indexed is dropped first.
  final int maxWatchedRoots;

  final DirectoryChangeWatcher _watcher;
  final DateTime Function() _now;

  final Map<String, _Indexed> _entries = {};
  final Map<String, Future<List<IndexedFile>>> _inFlight = {};
  final Map<String, int> _generation = {};

  /// Roots touched while a walk was running, against the generation of the
  /// walk that was running at the time.
  ///
  /// The generation is the whole point. A change noticed during walk *n* says
  /// nothing about walk *n+1*, which started afterwards and therefore already
  /// read the changed tree; marking that later result stale would send the
  /// index round the loop again for nothing.
  final Map<String, int> _dirtyAt = {};

  /// Watched roots, least recently indexed first.
  final ListQueue<String> _watchOrder = ListQueue();

  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  var _disposed = false;

  /// Emits a root whenever what is known about it changed: a walk landed, or
  /// something on disk made the cached answer stale. Quick open listens while
  /// it is open so a file created behind the dialog shows up in it.
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
  ///
  /// Cheap to call on every keystroke: a fresh root returns its cached list
  /// without touching the filesystem.
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
  ///
  /// This is the call a mutation path wants: the cached list stays available
  /// for an instant first frame, and the next [index] re-walks. [invalidate] is
  /// the blunter version, for when the cached answer is not merely old but
  /// wrong — the root itself moved.
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

  /// Abandons any walk of [root] in progress.
  ///
  /// Quick open calls this when it closes: a walk nobody is waiting for should
  /// not keep spending the UI isolate. Whatever the walk had already found is
  /// kept as a stale partial when nothing better is cached, so the next open
  /// still has something to draw immediately.
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

  /// Whether a changed path sits under one of the folders the walk skips.
  ///
  /// This filter is the difference between a watch that costs nothing and a
  /// watch that re-walks the repository every time a build writes a file: a
  /// recursive watch reports all of `build/` and `.dart_tool/`, none of which
  /// the index would have looked at anyway.
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

  /// The last path segment, without allocating a `RegExp` and a list per entry
  /// the way `path.split(RegExp(r'[\\/]')).last` did — on a twenty-thousand
  /// entry tree that was twenty thousand throwaway regular expressions.
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
      // Deterministic truncation. Which files survive a bound must not depend
      // on the order the filesystem happened to hand them back, or the same
      // repository indexes differently on two machines and a missing result
      // becomes unreproducible.
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        // With `followLinks: false` every symlink and every Windows junction
        // arrives as a `Link`, whatever it points at. Skipping them is what
        // stops a link back up the tree from making the walk a cycle, and what
        // stops one into `C:\` from making it a scan of the disk.
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
      // Give the frame back on a time budget rather than a directory count. A
      // fixed "every 24 directories" pays for a timer hop even when the last
      // twenty-four were instant, and skips one when a single directory took
      // eighty milliseconds — exactly backwards.
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
    // Something moved under us while *this* walk was reading, so what we just
    // built is already known to be behind. Publish it — a nearly-right list
    // beats an empty one — but do not let it look fresh.
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

/// One index for the app, so opening quick open twice does not walk twice.
///
/// The two signals listened to here are the app's own mutation notices, and
/// both notifiers build to a constant with no dependencies — listening costs
/// nothing and cannot drag a database into a test that only wanted an index.
/// `sessionsRevisionProvider` covers create, stop, archive, handoff and fork;
/// `checkpointsRevisionProvider` is bumped by the checkpoint recorder at the
/// end of an agent turn, which is precisely when an agent has stopped writing
/// files. Everything else — a checkout, a merge, a verification run, an agent
/// editing through a terminal the app never sees — arrives through the watcher.
final repoFileIndexProvider = Provider<RepoFileIndex>((ref) {
  final index = RepoFileIndex();
  ref.onDispose(index.dispose);
  ref.listen(sessionsRevisionProvider, (_, _) => index.touchAll());
  ref.listen(checkpointsRevisionProvider, (_, _) => index.touchAll());
  return index;
});

/// The root quick open indexes files under: the selected repository's, as a
/// host path. `null` when nothing is selected or the path cannot be resolved.
final quickOpenFileRootProvider = Provider<String?>(
  (ref) => ref.watch(selectedRepoWindowsRootProvider),
);
