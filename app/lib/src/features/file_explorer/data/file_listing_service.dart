import 'dart:io';

import 'package:path/path.dart' as p;

/// A single entry inside a listed directory. Paths are Windows-host paths —
/// the listing runs there, so WSL folders wear their UNC form.
class DirEntry {
  const DirEntry({
    required this.name,
    required this.isDirectory,
    required this.windowsPath,
  });

  final String name;
  final bool isDirectory;
  final String windowsPath;
}

/// Lists directory contents on the Windows host. Folders sort first, then names
/// alphabetically (case-insensitive).
class FileListingService {
  const FileListingService();

  Future<List<DirEntry>> list(String windowsDir) async {
    final dir = Directory(windowsDir);
    final entries = <DirEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final segments = entity.path
          .split(RegExp(r'[\\/]'))
          .where((s) => s.isNotEmpty);
      entries.add(
        DirEntry(
          name: segments.isEmpty ? entity.path : segments.last,
          isDirectory: entity is Directory,
          windowsPath: entity.path,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Makes the folder [name] in [parentDir] and answers its path. Refuses one
  /// that is already there rather than reporting it made.
  Future<String> createDirectory(String parentDir, String name) async {
    final dir = Directory(p.join(parentDir, name));
    if (await FileSystemEntity.type(dir.path) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('Something called "$name" is here', dir.path);
    }
    await dir.create();
    return dir.path;
  }

  /// Makes the empty file [name] in [parentDir] and answers its path. Never
  /// `create` alone: on a file that exists it does nothing and says nothing.
  Future<String> createFile(String parentDir, String name) async {
    final file = File(p.join(parentDir, name));
    if (await FileSystemEntity.type(file.path) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('Something called "$name" is here', file.path);
    }
    await file.create(exclusive: true);
    return file.path;
  }
}
