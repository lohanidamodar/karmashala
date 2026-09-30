import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';

/// The dashboard as it was last read, and when.
class StoreSnapshotFile {
  const StoreSnapshotFile({required this.savedAt, required this.apps});

  final DateTime savedAt;
  final List<StoreAppSnapshot> apps;
}

/// The last dashboard state as `stores_snapshot.json` in the app's data
/// folder, so the tab opens with data and its age. Holds no credential.
class StoreSnapshotStore {
  StoreSnapshotStore(this._directory);

  static const fileName = 'stores_snapshot.json';
  static const version = 1;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));

  /// Null when nothing was kept, or what was kept cannot be read as this
  /// version: no snapshot, never a failure.
  Future<StoreSnapshotFile?> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != version) return null;
      return StoreSnapshotFile(
        savedAt: DateTime.parse(json['savedAt'] as String).toUtc(),
        apps: [
          for (final app in json['apps'] as List)
            StoreAppSnapshot.fromJson((app as Map).cast<String, Object?>()),
        ],
      );
    } on Object {
      return null;
    }
  }

  Future<void> write(StoreSnapshotFile snapshot) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    // Written beside and renamed over, so a crash mid-write leaves the old one.
    final scratch = File('${file.path}.tmp');
    await scratch.writeAsString(
      jsonEncode({
        'version': version,
        'savedAt': snapshot.savedAt.toUtc().toIso8601String(),
        'apps': [for (final app in snapshot.apps) app.toJson()],
      }),
      flush: true,
    );
    await scratch.rename(file.path);
  }
}
