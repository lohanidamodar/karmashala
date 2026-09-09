import 'dart:async';
import 'dart:io';

import '../domain/vm_service_uri.dart';

/// One `--vmservice-out-file` and the address inside it.
class VmServiceUriFile {
  const VmServiceUriFile({required this.path, required this.uri});

  final String path;
  final Uri uri;

  /// What to call the app before we have talked to it: the file's basename
  /// without its extension, which is whatever the agent chose to call the run.
  String get label {
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

/// The directory Karmashala watches for the addresses **its own runs** write.
///
/// It is not a place anybody else is asked to write to. It used to be: the
/// empty pane offered a `--vmservice-out-file` pointed here, which meant
/// rewriting somebody's command to aim it into this app's private
/// application-support folder. Runs started elsewhere are found through their
/// tooling daemon now (`DtdPidFiles`), and a device's apps through its log.
///
/// **Why a directory of files and not a scan of terminal output.**
/// `flutter run --vmservice-out-file=<path>` writes the `ws://…/ws` address
/// and nothing else, which is a structured source with no parsing and no
/// ambiguity — the same mechanism VS Code's Dart extension uses in preference
/// to reading stdout. It also falls out right for several apps at once: a
/// desktop app, an app on the mirrored phone and one on a simulator are three
/// files, discovered and reconciled independently, with no agreement needed
/// between whoever started them.
///
/// **Why the directory is the durable half and the files are not.** §20's
/// distinction exactly. The path of this directory is stable and worth
/// keeping; the addresses in it die with the runs that wrote them, and
/// `flutter run` does not delete its file on the way out. So a file here is a
/// *candidate*, never a fact, and whether anything answers on it is measured
/// on demand — never on a timer.
class VmServiceUriDirectory {
  VmServiceUriDirectory(this.directory);

  final Directory directory;

  String get path => directory.path;

  Future<void> ensureExists() async {
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
  }

  /// Every readable address in the directory, in name order.
  ///
  /// Liberal about what it accepts and strict about what it keeps: any regular
  /// file is read, and one whose contents are not a VM service address is
  /// ignored rather than reported. The directory belongs to the user and may
  /// well hold a stray note.
  Future<List<VmServiceUriFile>> scan() async {
    if (!directory.existsSync()) return const <VmServiceUriFile>[];
    final found = <VmServiceUriFile>[];
    final List<FileSystemEntity> entries;
    try {
      entries = directory.listSync(followLinks: false);
    } on FileSystemException {
      return const <VmServiceUriFile>[];
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      if (entry is! File) continue;
      final String raw;
      try {
        raw = entry.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      // A file that is being written as we read it is empty, not broken; the
      // watch will bring us back when it has content.
      final uri = normaliseVmServiceUri(raw);
      if (uri == null) continue;
      found.add(VmServiceUriFile(path: entry.path, uri: uri));
    }
    return found;
  }

  /// Fires whenever the directory's contents change.
  ///
  /// This is the whole discovery mechanism and it is a subscription, not a
  /// poll: the OS reports the write, we look again. A host that cannot watch
  /// (a network share, a container without inotify) yields an empty stream and
  /// the panel's explicit re-check is then the only way in, which is why that
  /// button exists rather than being a fallback timer.
  Stream<FileSystemEvent> changes() {
    if (!directory.existsSync()) return const Stream<FileSystemEvent>.empty();
    try {
      return directory.watch();
    } on FileSystemException {
      return const Stream<FileSystemEvent>.empty();
    }
  }

  /// Deletes one address file.
  ///
  /// Offered for a file nothing answers on, and only when the user asks: the
  /// file was written by someone else's process and removing it silently would
  /// be this app deciding their run is over.
  Future<void> forget(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      await file.delete();
    } on FileSystemException {
      // Nothing to do about it and nothing to say: the row it belongs to
      // already reports that nothing answers there.
    }
  }
}
