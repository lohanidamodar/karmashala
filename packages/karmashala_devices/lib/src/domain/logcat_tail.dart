import 'dart:collection';

import 'logcat_entry.dart';

/// A bounded tail of `logcat` lines: the newest [capacity], and a count of what
/// was dropped. Bounded by **lines** because that is the number a reader can act
/// on, and [dropped] is counted and shown — a tail that silently discarded its
/// oldest lines looks identical to one that had seen nothing.
class LogcatTail {
  LogcatTail({this.capacity = 2000}) : assert(capacity > 0);

  /// How many lines are kept. Everything older is gone, not paged.
  final int capacity;

  final List<LogcatEntry> _entries = <LogcatEntry>[];
  int _dropped = 0;

  /// Lines discarded to stay within [capacity], since the last [clear].
  int get dropped => _dropped;

  int get length => _entries.length;

  /// Oldest first — the order a log is read in.
  List<LogcatEntry> get entries => UnmodifiableListView(_entries);

  void add(LogcatEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _dropped += _entries.length - capacity;
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  /// The newest [limit] entries at [minLevel] or above, oldest first. The level
  /// is applied here, not at adb: `logcat` filters by tag and priority together.
  List<LogcatEntry> tail({
    int limit = 400,
    LogLevel minLevel = LogLevel.verbose,
  }) {
    final matching = minLevel == LogLevel.verbose
        ? _entries
        : [
            for (final entry in _entries)
              if (entry.level.atLeast(minLevel)) entry,
          ];
    if (matching.length <= limit) return List.unmodifiable(matching);
    return List.unmodifiable(matching.sublist(matching.length - limit));
  }

  /// Empties the tail **and** the dropped count: a count of what was lost before
  /// a fresh reading would describe nothing on screen.
  void clear() {
    _entries.clear();
    _dropped = 0;
  }
}
