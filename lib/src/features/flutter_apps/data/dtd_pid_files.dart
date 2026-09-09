import 'dart:io';

import '../domain/dtd_instance.dart';

/// The directory every Dart Tooling Daemon on this machine records itself in.
///
/// One file per live daemon, named after its pid. The directory is the durable
/// half (§20): its path is stable, and the daemons in it die with the runs that
/// started them — so a file here is a candidate, never a fact.
class DtdPidFiles {
  const DtdPidFiles(this.path);

  /// Built from the environment, so a test hands over a temp directory.
  factory DtdPidFiles.forEnvironment(
    Map<String, String> environment, {
    required bool isWindows,
  }) => DtdPidFiles(dtdPidFileDirectory(environment, isWindows: isWindows));

  /// Where the files are, or null when this environment does not say — which
  /// is "we cannot look", not "there is nothing".
  final String? path;

  /// Every daemon that has written itself down, newest first.
  List<DtdInstance> scan() {
    final where = path;
    if (where == null) return const <DtdInstance>[];
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
      final name = entry.path.split(Platform.pathSeparator).last.split('/').last;
      final instance = parseDtdPidFile(name, raw);
      if (instance != null) found.add(instance);
    }
    found.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return found;
  }

  /// Fires when a daemon starts or stops. A subscription, not a poll.
  Stream<FileSystemEvent> changes() {
    final where = path;
    if (where == null) return const Stream<FileSystemEvent>.empty();
    final directory = Directory(where);
    if (!directory.existsSync()) return const Stream<FileSystemEvent>.empty();
    try {
      return directory.watch();
    } on FileSystemException {
      return const Stream<FileSystemEvent>.empty();
    }
  }
}
