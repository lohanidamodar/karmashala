import 'dart:async';
import 'dart:io';

import '../domain/vm_service_uri.dart';

/// One `--vmservice-out-file` and the address inside it.
class VmServiceUriFile {
  const VmServiceUriFile({required this.path, required this.uri});

  final String path;
  final Uri uri;

  /// What to call the app before we have talked to it: the file's basename.
  String get label {
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

/// The directory Karmashala watches for the addresses **its own runs** write;
/// runs started elsewhere are found through their tooling daemon instead.
///
/// `flutter run` does not delete its file on the way out, so a file here is a
/// candidate and never a fact: whether anything answers is measured on demand.
class VmServiceUriDirectory {
  VmServiceUriDirectory(this.directory);

  final Directory directory;

  String get path => directory.path;

  Future<void> ensureExists() async {
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
  }

  /// Every readable address in the directory, in name order. A file that is
  /// not an address is ignored — the directory belongs to the user.
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
      // A file caught mid-write reads empty; the watch brings us back.
      final uri = normaliseVmServiceUri(raw);
      if (uri == null) continue;
      found.add(VmServiceUriFile(path: entry.path, uri: uri));
    }
    return found;
  }

  /// Fires whenever the directory's contents change — a subscription, never a
  /// poll. A host that cannot watch yields an empty stream, and the panel's
  /// explicit re-check is then the only way in.
  Stream<FileSystemEvent> changes() {
    if (!directory.existsSync()) return const Stream<FileSystemEvent>.empty();
    try {
      return directory.watch();
    } on FileSystemException {
      return const Stream<FileSystemEvent>.empty();
    }
  }

  /// Deletes one address file, only when the user asks: it was written by
  /// someone else's process.
  Future<void> forget(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      await file.delete();
    } on FileSystemException {
      // The row already reports that nothing answers there.
    }
  }
}
