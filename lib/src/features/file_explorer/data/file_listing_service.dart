import 'dart:io';

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
}
