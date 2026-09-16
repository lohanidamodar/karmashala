import 'dart:async';
import 'dart:io';

import '../domain/dtd_instance.dart';

/// The directories the Dart Tooling Daemons on this machine record themselves
/// in, one file per pid. The directory is the durable half (§20): a file in it
/// is a candidate, never a fact.
class DtdPidFiles {
  const DtdPidFiles(this.paths);

  /// Built from the environment, so a test hands over a temp directory.
  factory DtdPidFiles.forEnvironment(
    Map<String, String> environment, {
    required String operatingSystem,
  }) => DtdPidFiles(
    dtdPidFileDirectories(environment, operatingSystem: operatingSystem),
  );

  /// Where the files may be; empty is "we cannot look", not "there is nothing".
  final List<String> paths;

  /// Every daemon that has written itself down, newest first, once per pid.
  List<DtdInstance> scan() {
    final byPid = <int, DtdInstance>{};
    for (final where in paths) {
      for (final instance in _scanOne(where)) {
        byPid.putIfAbsent(instance.pid, () => instance);
      }
    }
    return byPid.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  static List<DtdInstance> _scanOne(String where) {
    final directory = Directory(where);
    if (!directory.existsSync()) return const <DtdInstance>[];

    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return const <DtdInstance>[];
    }

    final found = <DtdInstance>[];
    for (final entry in entries) {
      if (entry is! File) continue;
      final String raw;
      try {
        raw = entry.readAsStringSync();
      } on FileSystemException {
        // Being written as we read it. The watch brings us back.
        continue;
      }
      final name = entry.path
          .split(Platform.pathSeparator)
          .last
          .split('/')
          .last;
      final instance = parseDtdPidFile(name, raw);
      if (instance != null) found.add(instance);
    }
    return found;
  }

  /// Fires when a daemon starts or stops. A directory not yet created (the SDK
  /// makes it on the first run) is waited for on its nearest existing ancestor.
  Stream<void> changes() {
    final watches = <_DirectoryWatch>[];
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () {
        for (final where in paths) {
          watches.add(_DirectoryWatch(where, controller)..arm());
        }
      },
      onCancel: () async {
        await Future.wait(watches.map((watch) => watch.cancel()));
        watches.clear();
      },
    );
    return controller.stream;
  }
}

class _DirectoryWatch {
  _DirectoryWatch(this.target, this.out);

  final String target;
  final StreamController<void> out;

  StreamSubscription<FileSystemEvent>? _subscription;
  String? _watching;
  bool _cancelled = false;

  void arm() {
    if (_cancelled) return;
    final watching = _nearestExisting(target);
    if (watching == null) return;
    final Stream<FileSystemEvent> events;
    try {
      events = Directory(watching).watch();
    } on FileSystemException catch (error) {
      out.addError(error);
      return;
    }
    final wasWaiting = _watching != null && _watching != target;
    _watching = watching;
    final onTarget = watching == target;
    _subscription = events.listen(
      (_) {
        if (onTarget) {
          out.add(null);
        } else if (_nearestExisting(target) != watching) {
          // Somewhere on the way to the target appeared; move closer.
          _rearm();
        }
      },
      onError: out.addError,
      onDone: () {
        // Only a vanished directory is re-armed, so a closed watch cannot loop.
        if (!Directory(watching).existsSync()) _rearm();
      },
      cancelOnError: false,
    );
    if (onTarget) {
      // Files written before this watch started are only found by looking.
      if (wasWaiting) out.add(null);
    } else if (_nearestExisting(target) != watching) {
      // The next step appeared between the check and the watch starting.
      _rearm();
    }
  }

  void _rearm() {
    final previous = _subscription;
    _subscription = null;
    unawaited(previous?.cancel());
    arm();
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _subscription?.cancel();
    _subscription = null;
  }

  static String? _nearestExisting(String path) {
    var current = Directory(path);
    while (true) {
      if (current.existsSync()) return current.path;
      final parent = current.parent;
      if (parent.path == current.path) return null;
      current = parent;
    }
  }
}
