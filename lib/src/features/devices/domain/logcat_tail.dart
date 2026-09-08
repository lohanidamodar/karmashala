import 'dart:collection';

import 'logcat_entry.dart';

/// A bounded tail of `logcat` lines: the newest [capacity], and a count of what
/// was dropped to keep it that size.
///
/// Bounded by **lines**, not by time or by bytes, because that is the number a
/// reader can act on: "1,000 kept, 12,431 dropped" says exactly what is missing
/// from the top of the list. A device under load logs faster than anybody
/// reads, so an unbounded buffer is not a longer history — it is the same
/// history plus a leak.
///
/// [dropped] is counted, never estimated, and it is shown. A tail that silently
/// discarded its oldest lines would look identical to one that had seen nothing
/// before the first line on screen, which is the same confident false statement
/// §19 deletes everywhere else.
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

  /// The newest [limit] entries at [minLevel] or above, oldest first.
  ///
  /// The level is applied here rather than at adb, exactly as
  /// `AdbService.readLogcat` applies it: `logcat` filters by tag and priority
  /// together and a bare priority filter would need a `*:` spec, so the one
  /// place either reader filters is this side.
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

  /// Empties the tail **and** the dropped count: the user asked for a fresh
  /// reading, so a count of what was lost before it would describe nothing on
  /// screen.
  void clear() {
    _entries.clear();
    _dropped = 0;
  }
}
