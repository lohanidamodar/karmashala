import 'dart:async';
import 'dart:io';

/// How a root is being watched, which is not the same question on every OS.
enum DirectoryWatchMode {
  /// One OS handle covers the whole tree — `ReadDirectoryChangesW`, FSEvents.
  recursive,

  /// No affordable recursive watch: Dart emulates one on inotify with a watch
  /// per directory, which a large tree turns into `max_user_watches`. The
  /// caller falls back to its own staleness interval.
  unsupported,
}

/// Opens the change stream for one root, as the paths that changed. Paths
/// rather than `FileSystemEvent`s, which have no public constructor and so
/// cannot be produced by a test.
typedef DirectoryChangeSource = Stream<String> Function(String root);

/// Watches directory trees and reports, at most once per quiet period, that
/// *something* under a root changed — deliberately not what, since the consumer
/// can only re-walk.
///
/// [debounce] restarts on every event so a burst lands as one callback;
/// [maxDebounce] caps the wait from the burst's *first* event, so a build that
/// writes continuously still reports.
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
  /// Returns whether a watch was established, and never throws: a root that
  /// cannot be watched refreshes on its interval instead. [ignore] filters
  /// events by path, which a repository root needs — a build writing into
  /// `build/` and `.dart_tool/` would otherwise re-walk the tree constantly.
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
