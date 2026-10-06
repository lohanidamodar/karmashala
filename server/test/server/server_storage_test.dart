import 'dart:io';

import 'package:karmashala_host/src/serve/tool_image_upkeep.dart';
import 'package:karmashala_host/src/server/server_storage.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `server.storage` and the cache calls beside it: what Settings → Server →
/// Storage reads and does, answered by the server that owns the files.
void main() {
  late Directory data;
  late AppDatabase database;
  late Directory cache;
  late ServerStorage storage;
  var limits = ToolImageLimits.fromSettings(null);

  setUp(() {
    data = Directory.systemTemp.createTempSync('kh-storage');
    database = AppDatabase.open(data);
    cache = Directory(p.join(data.path, 'tool-images'))..createSync();
    limits = ToolImageLimits.fromSettings(null);
    storage = ServerStorage(
      dataDirectory: data.path,
      database: database,
      toolImages: cache,
      limits: () => limits,
    );
  });
  tearDown(() {
    database.close();
    try {
      data.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holding a handle, not the case's verdict.
    }
  });

  test('reads the database size and the largest tables', () {
    for (var i = 0; i < 50; i++) {
      database.writeMetadata('k$i', 'x' * 2000);
    }
    final reading = storage.read();

    expect(reading['databaseBytes'], isA<int>());
    expect(reading['databaseBytes']! as int, greaterThan(0));
    final tables = reading['tables'] as List?;
    // dbstat is compiled into the bundled SQLite; were it not, the reading
    // would leave the tables out rather than invent sizes.
    expect(tables, isNotNull);
    final names = [for (final t in tables!) (t as Map)['name']];
    expect(names, contains('app_metadata'));
    final sizes = [for (final t in tables) (t as Map)['bytes'] as int];
    expect(sizes, orderedEquals([...sizes]..sort((a, b) => b - a)));
    expect(tables.length, lessThanOrEqualTo(ServerStorage.largestTables));
  });

  test('reads the tool-image cache and its limits', () {
    File(p.join(cache.path, 'a-1.png')).writeAsBytesSync(List.filled(12, 1));
    limits = ToolImageLimits.fromSettings(
      '{"toolImageMaxAgeDays": 5, "toolImageMaxMegabytes": 32}',
    );

    final images = storage.read()['toolImages']! as Map;
    expect(images['files'], 1);
    expect(images['bytes'], 12);
    expect(images['maxAgeDays'], 5);
    expect(images['maxMegabytes'], 32);
  });

  test('clears the cache, and sweeps it by the limits as they are now', () {
    final old = File(p.join(cache.path, 'old-1.png'))
      ..writeAsBytesSync([1])
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 4)));
    final fresh = File(p.join(cache.path, 'new-1.png'))..writeAsBytesSync([1]);

    limits = ToolImageLimits.fromSettings('{"toolImageMaxAgeDays": 3}');
    expect(storage.sweepToolImages()['removed'], 1);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);

    expect(storage.clearToolImages()['removed'], 1);
    expect(fresh.existsSync(), isFalse);
  });
}
