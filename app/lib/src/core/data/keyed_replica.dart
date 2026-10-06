import 'dart:async';
import 'dart:collection';

/// One row the server's word moved in a [KeyedReplica]: what it was, and
/// what it is now — null for absent.
class ReplicaChange<V> {
  const ReplicaChange(
    this.key,
    this.before,
    this.after, {
    this.overridesLocal = false,
  });

  final String key;
  final V? before;
  final V? after;

  /// Whether this app had written [key] locally and not yet heard back: the
  /// server's word differs from what it asked — a rule it applied, a value
  /// it ignored — so what the writer announced is no longer what the copy
  /// holds, even when this is the answer to that very write.
  final bool overridesLocal;
}

/// This app's copy of one domain's rows at the server, keyed by id, kept by
/// what the server says and when: each row remembers the revision it was
/// last told at, so a late answer never overwrites a newer change. A local
/// write lands at once, unrevisioned, until the server's word replaces it.
class KeyedReplica<V> {
  /// [_equals] says when two rows are the same — by `==` when not given.
  KeyedReplica([this._equals]);

  final bool Function(V a, V b)? _equals;
  final _rows = <String, V>{};
  late final _view = UnmodifiableMapView(_rows);
  final _revisions = <String, int>{};

  /// Local writes per key the server has not yet said anything on.
  final _unanswered = <String, int>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  final _serverChanges = StreamController<ReplicaChange<V>>.broadcast(
    sync: true,
  );
  var _primed = false;
  var _version = 0;

  /// Moves on every change: a reader that keeps something derived from the
  /// rows knows when to derive it again.
  int get version => _version;

  /// Whether a snapshot has been taken; before it, nothing here is known.
  bool get isPrimed => _primed;

  /// Fires after every change, synchronously.
  Stream<void> get changes => _changes.stream;

  /// Each row the server's word moved — another client's write, one the
  /// server made itself, or a snapshot that differs — but not this app's own
  /// local write, which its writer already announced. Synchronous.
  Stream<ReplicaChange<V>> get serverChanges => _serverChanges.stream;

  V? operator [](String key) => _rows[key];

  Iterable<V> get values => _rows.values;

  Map<String, V> get asMap => Map.unmodifiable(_rows);

  /// The rows as they stand, without a copy — for a reader on a timer.
  Map<String, V> get view => _view;

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
    _unanswered.clear();
    final wasPrimed = _primed;
    _primed = true;
    if (!wasPrimed || !_sameRows(before)) _changed();
    if (!wasPrimed || !_serverChanges.hasListener) return;
    for (final entry in before.entries) {
      final after = _rows[entry.key];
      if (after == null || !_same(after, entry.value)) {
        _serverChanges.add(ReplicaChange(entry.key, entry.value, after));
      }
    }
    for (final entry in _rows.entries) {
      if (!before.containsKey(entry.key)) {
        _serverChanges.add(ReplicaChange(entry.key, null, entry.value));
      }
    }
  }

  /// The server's word on [key] at [revision] — [value] null is removed.
  /// Ignored when an answer this copy already has is newer, and before the
  /// first snapshot.
  void applyAt(String key, V? value, int revision) {
    if (!_primed) return;
    final overridesLocal = _heardOn(key);
    final known = _revisions[key];
    if (known != null && known > revision) return;
    _revisions[key] = revision;
    final before = _rows[key];
    if (_set(key, value) && _serverChanges.hasListener) {
      _serverChanges.add(
        ReplicaChange(key, before, value, overridesLocal: overridesLocal),
      );
    }
  }

  /// A write this app just made, before the server has answered it.
  void setLocal(String key, V? value) {
    if (!_primed) return;
    _unanswered.update(key, (count) => count + 1, ifAbsent: () => 1);
    _set(key, value);
  }

  /// Whether a local write to [key] was waiting for the server's word, which
  /// this is: one fewer is now.
  bool _heardOn(String key) {
    final count = _unanswered[key];
    if (count == null) return false;
    if (count <= 1) {
      _unanswered.remove(key);
    } else {
      _unanswered[key] = count - 1;
    }
    return true;
  }

  /// [setLocal] to null for every one of [keys], as one change.
  void removeLocal(Iterable<String> keys) {
    hold();
    try {
      for (final key in keys) {
        setLocal(key, null);
      }
    } finally {
      release();
    }
  }

  var _holds = 0;
  var _changedWhileHeld = false;

  /// Holds [changes] until the matching [release], which fires it once if
  /// anything moved: a batch of N rows wakes each listener once, not N times.
  void hold() => _holds++;

  void release() {
    if (_holds == 0 || --_holds > 0 || !_changedWhileHeld) return;
    _changedWhileHeld = false;
    if (!_changes.isClosed) _changes.add(null);
  }

  void _changed() {
    _version++;
    if (_holds > 0) {
      _changedWhileHeld = true;
    } else {
      _changes.add(null);
    }
  }

  /// Whether [key] changed.
  bool _set(String key, V? value) {
    if (value == null) {
      if (_rows.remove(key) == null) return false;
      _changed();
      return true;
    }
    final current = _rows[key];
    if (current != null && _same(current, value)) return false;
    _rows[key] = value;
    _changed();
    return true;
  }

  bool _sameRows(Map<String, V> before) {
    if (before.length != _rows.length) return false;
    for (final entry in before.entries) {
      final now = _rows[entry.key];
      if (now == null || !_same(now, entry.value)) return false;
    }
    return true;
  }

  bool _same(V a, V b) => _equals?.call(a, b) ?? a == b;

  Future<void> dispose() async {
    await _serverChanges.close();
    await _changes.close();
  }
}
