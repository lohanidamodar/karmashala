import 'dart:io';

import 'package:agent_cli/stream.dart' as images show sweepToolImages;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../serve/tool_image_upkeep.dart';

/// What the server keeps on disk, as Settings → Server → Storage reads it:
/// the database, its largest tables, and the tool-image cache. Read when
/// asked, never on a timer.
class ServerStorage {
  ServerStorage({
    required this.dataDirectory,
    required this.database,
    required this.toolImages,
    required this.limits,
  });

  final String dataDirectory;
  final AppDatabase database;
  final Directory toolImages;
  final ToolImageLimits Function() limits;

  /// How many tables the reading names, largest first.
  static const largestTables = 6;

  /// `{databaseBytes, tables?: [{name, bytes}], toolImages: {files, bytes,
  /// maxAgeDays, maxMegabytes}}`. `tables` is left out when this SQLite has
  /// no `dbstat`, rather than guessed.
  Map<String, Object?> read() {
    final cache = readToolImageCache(toolImages);
    final limits = this.limits();
    return {
      'databaseBytes': _databaseBytes(),
      'tables': ?_largestTables(),
      'toolImages': {
        'files': cache.files,
        'bytes': cache.bytes,
        'maxAgeDays': limits.maxAge.inDays,
        'maxMegabytes': limits.maxBytes ~/ (1024 * 1024),
      },
    };
  }

  /// `{removed}`: every cached image deleted.
  Map<String, Object?> clearToolImages() => {
    'removed': clearToolImageCache(toolImages),
  };

  /// `{removed}`: the cache swept by the limits as they are now, so a change
  /// in Settings takes effect without waiting for the daily sweep.
  Map<String, Object?> sweepToolImages() {
    final now = limits();
    return {
      'removed': images.sweepToolImages(
        toolImages,
        maxAge: now.maxAge,
        maxBytes: now.maxBytes,
      ),
    };
  }

  /// The store file with its WAL and shared-memory files beside it.
  int _databaseBytes() {
    var total = 0;
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File(p.join(dataDirectory, '$kStoreFileName$suffix'));
      try {
        total += file.lengthSync();
      } on FileSystemException {
        // Not there: a store without a WAL yet.
      }
    }
    return total;
  }

  List<Map<String, Object?>>? _largestTables() {
    try {
      return [
        for (final row in database.query(
          'SELECT name, SUM(pgsize) AS bytes FROM dbstat '
          "WHERE name NOT LIKE 'sqlite_%' GROUP BY name "
          'ORDER BY bytes DESC LIMIT ?',
          [largestTables],
        ))
          {'name': row['name'], 'bytes': row['bytes']},
      ];
    } on Object {
      return null;
    }
  }
}
