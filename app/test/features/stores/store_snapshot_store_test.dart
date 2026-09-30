import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/stores/data/store_snapshot_store.dart';
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';

import 'store_fixtures.dart';

void main() {
  late Directory directory;
  late StoreSnapshotStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('stores_snapshot_test');
    store = StoreSnapshotStore(() async => directory);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  File file() => File(p.join(directory.path, StoreSnapshotStore.fileName));

  test('nothing kept is no snapshot', () async {
    expect(await store.read(), isNull);
  });

  test('what is written is read back, missing readings included', () async {
    final app = storeApp(
      StoreKind.appStore,
      'com.example.notes',
      name: 'Notes',
    );
    final savedAt = DateTime.utc(2026, 9, 30, 9, 15);
    await store.write(
      StoreSnapshotFile(
        savedAt: savedAt,
        apps: [
          storeSnapshot(
            app,
            releases: [
              storeRelease(ReleaseState.rollingOut, rolloutFraction: 0.5),
            ],
            downloads: ReadingMissing(
              StoreFailure.notConfigured,
              'Add the vendor number in Settings → Stores.',
              fixtureCheckedAt,
            ),
          ),
        ],
      ),
    );

    final kept = (await store.read())!;
    expect(kept.savedAt, savedAt);
    final snapshot = kept.apps.single;
    expect(snapshot.app, app);
    expect(snapshot.app.name, 'Notes');
    expect(snapshot.live?.rolloutFraction, 0.5);
    expect(snapshot.rating.valueOrNull?.average, 4.6);
    final downloads = snapshot.downloads as ReadingMissing<DownloadSeries>;
    expect(downloads.expected, isTrue);
    expect(downloads.message, 'Add the vendor number in Settings → Stores.');
    // No scratch file is left beside it.
    expect(directory.listSync().map((entry) => p.basename(entry.path)), [
      StoreSnapshotStore.fileName,
    ]);
  });

  test('another version, or a file that is not JSON, is no snapshot', () async {
    file().writeAsStringSync('{"version": 2, "savedAt": "x", "apps": []}');
    expect(await store.read(), isNull);

    file().writeAsStringSync('not json');
    expect(await store.read(), isNull);

    file().writeAsStringSync('{"version": 1, "apps": [{"app": 7}]}');
    expect(await store.read(), isNull);
  });
}
