import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Removes the `<checkpointId>/` folders that hold [pngPaths], the stored paths
/// of a dropped checkpoint's screenshots. Best-effort: never throws, never
/// waits.
void deleteCheckpointScreenshotFolders(
  Iterable<String> pngPaths,
  Set<String> checkpointIds,
) {
  final folders = {
    for (final path in pngPaths)
      if (checkpointIds.contains(p.basename(p.dirname(path)))) p.dirname(path),
  };
  for (final folder in folders) {
    unawaited(
      Directory(folder).delete(recursive: true).then((_) {}, onError: (_) {}),
    );
  }
}

/// Deletes each folder under [directory] that [isCheckpoint] does not name — a
/// checkpoint dropped while its files could not be, or by a path that does not
/// know them. Answers how many went; never throws.
Future<int> sweepCheckpointScreenshotFolders(
  String directory,
  bool Function(String checkpointId) isCheckpoint,
) async {
  var removed = 0;
  try {
    final root = Directory(directory);
    if (!await root.exists()) return 0;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;
      if (isCheckpoint(p.basename(entry.path))) continue;
      try {
        await entry.delete(recursive: true);
        removed++;
      } on FileSystemException {
        // Locked or already gone; the next start tries again.
      }
    }
  } on Object {
    // A sweep that fails leaves files, never a failed start.
  }
  return removed;
}
