import 'dart:async';

/// This app's copy of one domain's rows at the server, keyed by id, kept by
/// what the server says and when: each row remembers the revision it was
/// last told at, so a late answer never overwrites a newer change. A local
/// write lands at once, unrevisioned, until the server's word replaces it.
class KeyedReplica<V> {
  final _rows = <String, V>{};
  final _revisions = <String, int>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  var _primed = false;

  /// Whether a snapshot has been taken; before it, nothing here is known.
  bool get isPrimed => _primed;

  /// Fires after every change, synchronously.
  Stream<void> get changes => _changes.stream;

  V? operator [](String key) => _rows[key];

  Iterable<V> get values => _rows.values;

  Map<String, V> get asMap => Map.unmodifiable(_rows);

  /// Everything, as the server holds it at [revision]. Forgets what was
  /// remembered: a snapshot is whole.
  void replaceAll(Map<String, V> rows, int revision) {
    final before = Map.of(_rows);
    _rows
      ..clear()
      ..addAll(rows);
    _revisions
      ..clear()
      ..addEntries(rows.keys.map((key) => MapEntry(key, revision)));
    final wasPrimed = _primed;
    _primed = true;
    if (!wasPrimed || !_sameRows(before)) _changes.add(null);
  }

  /// The server's word on [key] at [revision] — [value] null is removed.
  /// Ignored when an answer this copy already has is newer, and before the
  /// first snapshot.
  void applyAt(String key, V? value, int revision) {
    if (!_primed) return;
    final known = _revisions[key];
    if (known != null && known > revision) return;
    _revisions[key] = revision;
    _set(key, value);
  }

  /// A write this app just made, before the server has answered it.
  void setLocal(String key, V? value) {
    if (!_primed) return;
    _set(key, value);
  }

  void _set(String key, V? value) {
    if (value == null) {
      if (_rows.remove(key) != null) _changes.add(null);
      return;
    }
    if (_rows[key] == value) return;
    _rows[key] = value;
    _changes.add(null);
  }

  bool _sameRows(Map<String, V> before) {
    if (before.length != _rows.length) return false;
    for (final entry in before.entries) {
      if (_rows[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<void> dispose() => _changes.close();
}
