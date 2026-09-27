import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/karmashala_files.dart';

import '../data/files_work.dart';

/// **The paths clients watch, per link** (`files.watch`, slice 3c). One stat
/// per watched path on a cadence of its environment's ([intervalOf]) — the
/// same on this machine, over the WSL share (where an OS watch says nothing
/// of what Linux wrote) and over SFTP (which has no watch) — and whenever the
/// server has reason to think one moved ([check]: its own write, an agent's
/// turn ending there). A stamp that differs from the last one seen is told
/// as [FileChanged] to each link watching that path, and to no other.
///
/// A stat that fails tells nothing: an environment that did not answer is not
/// evidence a file changed.
class FileWatches {
  FileWatches({
    required this.stat,
    required this.intervalOf,
    this.tick = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// A path's stamp now; null when nothing is there. Throws when its
  /// environment did not answer.
  final Future<FileStamp?> Function(EnvironmentPath path) stat;

  /// How often a path in an environment is stat-ed with nothing else to go
  /// on.
  final Duration Function(String environmentId) intervalOf;

  /// How often the watches are looked over for one that is due.
  final Duration tick;

  final DateTime Function() _now;

  final _watched = <EnvironmentPath, _Watched>{};
  Timer? _timer;

  /// Every path watched by anyone — for a test, a diagnostic.
  Iterable<EnvironmentPath> get paths => _watched.keys;

  /// [link] watches [paths] from now on. Answers once each new path has been
  /// seen as it stands, so a change after the answer is one this tells.
  Future<void> watch(FileWatchLink link, List<EnvironmentPath> paths) async {
    final fresh = <_Watched>[];
    for (final path in paths) {
      final watched = _watched.putIfAbsent(path, () {
        final made = _Watched(path);
        fresh.add(made);
        return made;
      });
      watched.links.add(link);
    }
    await Future.wait([for (final watched in fresh) _baseline(watched)]);
    _arm();
  }

  /// [link] stops watching [paths]; a path nobody watches is dropped.
  void unwatch(FileWatchLink link, List<EnvironmentPath> paths) {
    for (final path in paths) {
      final watched = _watched[path];
      if (watched == null) continue;
      watched.links.remove(link);
      if (watched.links.isEmpty) _watched.remove(path);
    }
    _arm();
  }

  /// [link] closed: everything it watched is dropped with it.
  void closed(FileWatchLink link) {
    for (final path in _watched.keys.toList()) {
      final watched = _watched[path]!;
      watched.links.remove(link);
      if (watched.links.isEmpty) _watched.remove(path);
    }
    _arm();
  }

  /// Looks at [paths] now, whatever their cadence says — and at every watched
  /// path under a folder among them when [under].
  Future<void> check(Iterable<EnvironmentPath> paths, {bool under = false}) {
    final due = <_Watched>{};
    for (final path in paths) {
      final exact = _watched[path];
      if (exact != null) due.add(exact);
      if (!under) continue;
      for (final watched in _watched.values) {
        if (_isUnder(path, watched.path)) due.add(watched);
      }
    }
    return Future.wait([for (final watched in due) _look(watched)]);
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    _watched.clear();
  }

  void _arm() {
    if (_watched.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(tick, (_) => _sweep());
  }

  void _sweep() {
    final now = _now();
    for (final watched in _watched.values.toList()) {
      if (watched.looking || now.isBefore(watched.nextAt)) continue;
      unawaited(_look(watched));
    }
  }

  Future<void> _baseline(_Watched watched) async {
    try {
      watched.last = await stat(watched.path);
      watched.seen = true;
    } on Object {
      // Seen at the next look instead.
    }
    watched.nextAt = _now().add(intervalOf(watched.path.environmentId));
  }

  Future<void> _look(_Watched watched) async {
    if (watched.looking) return;
    watched.looking = true;
    try {
      final FileStamp? now;
      try {
        now = await stat(watched.path);
      } on Object {
        return;
      }
      final before = watched.last;
      final wasSeen = watched.seen;
      watched
        ..last = now
        ..seen = true;
      if (!wasSeen || _same(before, now)) return;
      if (!identical(_watched[watched.path], watched)) return;
      final change = FileChanged(
        environmentId: watched.path.environmentId,
        path: watched.path.path,
        stamp: now,
      );
      for (final link in watched.links.toList()) {
        link.tell([change]);
      }
    } finally {
      watched
        ..looking = false
        ..nextAt = _now().add(intervalOf(watched.path.environmentId));
    }
  }

  static bool _same(FileStamp? a, FileStamp? b) =>
      a == null ? b == null : (b != null && a == b);

  static bool _isUnder(EnvironmentPath folder, EnvironmentPath path) {
    if (folder.environmentId != path.environmentId) return false;
    final outer = folder.path.replaceAll(r'\', '/');
    final inner = path.path.replaceAll(r'\', '/');
    return inner == outer ||
        inner.startsWith(outer.endsWith('/') ? outer : '$outer/');
  }
}

class _Watched {
  _Watched(this.path);

  final EnvironmentPath path;
  final links = <FileWatchLink>{};
  FileStamp? last;

  /// Whether [last] is a reading at all — a baseline that failed is not
  /// "absent", and must not make the first real reading look like a change.
  bool seen = false;
  bool looking = false;
  DateTime nextAt = DateTime.fromMillisecondsSinceEpoch(0);
}
