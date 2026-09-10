import 'log_entry.dart';

/// How many records the in-memory buffer keeps by default.
const int kDefaultLogBufferCapacity = 5000;

/// The smallest and largest buffer the settings screen will let you choose.
const int kMinLogBufferCapacity = 200;
const int kMaxLogBufferCapacity = 50000;

/// A bounded ring of the most recent [LogEntry]s, always filling — a buffer
/// that starts recording when the panel opens is empty for the person who has
/// just watched something fail.
///
/// [add] never blocks, allocates or calls a listener; a UI notices new records
/// by watching [revision] instead.
class LogRingBuffer {
  LogRingBuffer({int capacity = kDefaultLogBufferCapacity})
    : _capacity = capacity.clamp(kMinLogBufferCapacity, kMaxLogBufferCapacity),
      _slots = List<LogEntry?>.filled(
        capacity.clamp(kMinLogBufferCapacity, kMaxLogBufferCapacity),
        null,
      );

  List<LogEntry?> _slots;
  int _capacity;
  int _next = 0;
  int _filled = 0;
  int _written = 0;
  int _dropped = 0;

  int get capacity => _capacity;

  /// How many records are held right now.
  int get length => _filled;

  /// Total records ever offered this run, so a UI that remembers the last value
  /// it rendered knows whether a repaint is worth doing.
  int get revision => _written;

  /// How many records the bound has evicted.
  int get dropped => _dropped;

  /// Stores [entry], evicting the oldest record once the bound is reached.
  void add(LogEntry entry) {
    _slots[_next] = entry;
    _next = _next + 1 == _capacity ? 0 : _next + 1;
    if (_filled < _capacity) {
      _filled++;
    } else {
      _dropped++;
    }
    _written++;
  }

  /// Every held record, oldest first, as a fresh list a caller can hold across
  /// frames.
  List<LogEntry> snapshot() {
    final out = <LogEntry>[];
    var index = (_next - _filled) % _capacity;
    if (index < 0) index += _capacity;
    for (var i = 0; i < _filled; i++) {
      final entry = _slots[index];
      if (entry != null) out.add(entry);
      index = index + 1 == _capacity ? 0 : index + 1;
    }
    return out;
  }

  /// The newest [count] records, oldest first — what "copy the last N" wants.
  List<LogEntry> tail(int count) {
    final all = snapshot();
    return count >= all.length ? all : all.sublist(all.length - count);
  }

  /// Changes the bound, keeping the newest records that still fit.
  void resize(int capacity) {
    final wanted = capacity.clamp(kMinLogBufferCapacity, kMaxLogBufferCapacity);
    if (wanted == _capacity) return;
    final kept = tail(wanted);
    _dropped += _filled - kept.length;
    _capacity = wanted;
    _slots = List<LogEntry?>.filled(wanted, null);
    for (var i = 0; i < kept.length; i++) {
      _slots[i] = kept[i];
    }
    _filled = kept.length;
    _next = kept.length == wanted ? 0 : kept.length;
  }

  /// Drops everything held. [revision] keeps counting: a UI watching it must
  /// still notice that the list it was rendering is gone.
  void clear() {
    _slots = List<LogEntry?>.filled(_capacity, null);
    _next = 0;
    _filled = 0;
    _written++;
  }
}
