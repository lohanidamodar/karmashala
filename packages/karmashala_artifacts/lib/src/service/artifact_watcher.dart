import 'dart:async';

import 'artifact_library.dart';
import 'artifact_sources.dart';

/// Polls the stat of every artifact read from a host file and refreshes one
/// whose stamp moved. Polled, not `Directory.watch`ed: a watch on a WSL share
/// subscribes and never fires, and an SSH host has none (PROJECT.md §18).
class ArtifactWatcher {
  ArtifactWatcher(
    this._library, {
    required this._sources,
    Duration Function(String environmentId)? intervalOf,
    DateTime Function()? now,
  }) : _intervalOf = intervalOf ?? ((_) => const Duration(seconds: 2)),
       _now = now ?? DateTime.now;

  final ArtifactLibrary _library;
  final ArtifactSources _sources;
  final Duration Function(String environmentId) _intervalOf;
  final DateTime Function() _now;

  final _stamps = <String, String>{};
  final _lookedAt = <String, DateTime>{};
  Timer? _timer;
  var _checking = false;

  /// Looks every [tick]; each artifact no more often than its host's interval.
  void start({Duration tick = const Duration(milliseconds: 500)}) {
    _timer ??= Timer.periodic(tick, (_) => unawaited(check(due: true)));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass. [due] skips an artifact looked at within its host's interval.
  Future<void> check({bool due = false}) async {
    if (_checking) return;
    _checking = true;
    try {
      final now = _now();
      for (final artifact in _library.watched()) {
        final source = artifact.source;
        if (source == null) continue;
        final last = _lookedAt[artifact.id];
        if (due &&
            last != null &&
            now.difference(last) < _intervalOf(source.environmentId)) {
          continue;
        }
        _lookedAt[artifact.id] = now;
        String stamp;
        try {
          stamp = (await _sources.stat(source)).stamp;
        } on Object catch (error) {
          stamp = 'unreachable: $error';
        }
        if (_stamps[artifact.id] == stamp) continue;
        _stamps[artifact.id] = stamp;
        await _library.refresh(artifact.id);
      }
    } finally {
      _checking = false;
    }
  }
}
