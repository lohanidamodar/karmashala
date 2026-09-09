import 'dart:async';
import 'dart:io';

/// How a root is being watched, which is not the same question on every OS.
enum DirectoryWatchMode {
  /// One OS handle covers the whole tree. On Windows that is
  /// `ReadDirectoryChangesW`, which is genuinely recursive and costs one handle
  /// per root however deep the tree is; on macOS it is FSEvents, likewise.
  recursive,

  /// No affordable recursive watch. Linux has only inotify, which has no
  /// recursive mode at all: Dart emulates `recursive: true` by adding a watch
  /// per directory, so a twenty-thousand-directory tree wants twenty thousand
  /// inotify watches and usually hits `max_user_watches` instead. The caller
  /// falls back to its own staleness interval.
  unsupported,
}

/// Opens the change stream for one root, as the paths that changed.
///
/// Paths rather than `FileSystemEvent`s for two reasons: the path is the only
/// part of an event this class reads, and `FileSystemEvent` has no public
/// constructor, so a typedef over it is one a test can never satisfy.
typedef DirectoryChangeSource = Stream<String> Function(String root);

/// Watches directory trees and reports, at most once per quiet period, that
/// *something* under a root changed.
///
/// **It deliberately says nothing about what changed.** The consumer here is an
/// index that can only re-walk, so the useful signal is one debounced bit per
/// root; delivering an event per file would just make the caller coalesce them
/// again, having already paid to allocate them.
///
/// Two timers guard the callback. [debounce] restarts on every event, so a
/// burst — a checkout, an agent writing twenty files — lands as one callback
/// once it settles. [maxDebounce] caps the total wait from the *first* event of
/// a burst, so a build that writes continuously for a minute still reports
/// within a few seconds instead of never.
class DirectoryChangeWatcher {
  DirectoryChangeWatcher({
    this.debounce = const Duration(milliseconds: 400),
    this.maxDebounce = const Duration(seconds: 3),
    DirectoryChangeSource? source,
    bool? recursiveWatchSupported,
  }) : _source = source ?? _watchRoot,
       _supported =
           recursiveWatchSupported ?? (Platform.isWindows || Platform.isMacOS);

  final Duration debounce;
  final Duration maxDebounce;
  final DirectoryChangeSource _source;
  final bool _supported;

  final Map<String, _Watch> _watches = {};
  var _disposed = false;

  static Stream<String> _watchRoot(String root) =>
      Directory(root).watch(recursive: true).map((event) => event.path);

  DirectoryWatchMode get mode => _supported
      ? DirectoryWatchMode.recursive
      : DirectoryWatchMode.unsupported;

  /// The roots currently watched. A root that failed to watch is not here, and
  /// the caller should treat it as needing its own staleness interval.
  Iterable<String> get watched => _watches.keys;

  bool isWatching(String root) => _watches.containsKey(root);

  /// Starts watching [root], calling [onChange] once per settled burst.
  ///
  /// Returns whether a watch was established. `false` means this platform has
  /// no affordable recursive watch, the path is not watchable, or the OS
  /// refused — never an exception, because a repository that cannot be watched
  /// is a repository that refreshes on its interval, not a broken app.
  ///
  /// [ignore] filters events by path before they count. Passing the index's own
  /// skip list here matters more than it looks: a recursive watch over a
  /// repository root reports every file a build writes into `build/` and
  /// `.dart_tool/`, and re-walking on those is pure waste.
  bool watch(
    String root,
    void Function() onChange, {
    bool Function(String path)? ignore,
  }) {
    if (_disposed || !_supported) return false;
    if (_watches.containsKey(root)) return true;
    final watch = _Watch(onChange: onChange, ignore: ignore);
    try {
      watch.subscription = _source(root).listen(
        (path) => _onEvent(root, path),
        // A watch that dies (handle closed, buffer overflow, the root deleted)
        // drops back to interval refresh rather than taking the app with it.
        onError: (Object _) => unwatch(root),
        onDone: () => unwatch(root),
        cancelOnError: true,
      );
    } catch (_) {
      return false;
    }
    _watches[root] = watch;
    return true;
  }

  void _onEvent(String root, String path) {
    final watch = _watches[root];
    if (watch == null) return;
    if (watch.ignore?.call(path) ?? false) return;
    watch.quiet?.cancel();
    watch.quiet = Timer(debounce, () => _fire(root));
    watch.ceiling ??= Timer(maxDebounce, () => _fire(root));
  }

  void _fire(String root) {
    final watch = _watches[root];
    if (watch == null) return;
    watch.quiet?.cancel();
    watch.quiet = null;
    watch.ceiling?.cancel();
    watch.ceiling = null;
    watch.onChange();
  }

  void unwatch(String root) => _watches.remove(root)?.cancel();

  void dispose() {
    _disposed = true;
    for (final watch in _watches.values) {
      watch.cancel();
    }
    _watches.clear();
  }
}

class _Watch {
  _Watch({required this.onChange, this.ignore});

  final void Function() onChange;
  final bool Function(String path)? ignore;
  StreamSubscription<String>? subscription;
  Timer? quiet;
  Timer? ceiling;

  void cancel() {
    quiet?.cancel();
    ceiling?.cancel();
    subscription?.cancel();
  }
}
