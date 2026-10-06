import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// The Stores tab's view while a refresh runs: each app's own state, told
/// one app at a time, and one app read again on its own.
void main() {
  final t0 = DateTime.utc(2026, 10, 6, 8);
  const app = StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.example.one',
    bundleId: 'com.example.one',
    name: 'One',
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  StoreAppSnapshot snapshot(DateTime at) => StoreAppSnapshot(
    app: app,
    releases: ReadingValue(const [], at),
    reviews: ReadingValue(const [], at),
    rating: ReadingValue(const RatingSummary(average: 4.2, count: 3), at),
    vitals: ReadingMissing(StoreFailure.notSupported, 'Not here.', at),
    downloads: ReadingMissing(StoreFailure.notConfigured, 'No bucket.', at),
  );

  test('a view carries each app\'s read state over the wire', () {
    final view = StoresView(
      reads: {
        app.key: const StoreAppRead.queued(),
        'appStore:2': const StoreAppRead.reading(),
        'appStore:3': StoreAppRead.failed('The store did not answer.', t0),
      },
    );
    final back = StoresView.fromJson(overTheWire(view.toJson()));
    expect(back.reads[app.key]!.phase, StoreAppReadPhase.queued);
    expect(back.reads['appStore:2']!.phase, StoreAppReadPhase.reading);
    final failed = back.reads['appStore:3']!;
    expect(failed.phase, StoreAppReadPhase.failed);
    expect(failed.message, 'The store did not answer.');
    expect(failed.at, t0);
  });

  test('a view from an older server has no read states', () {
    final json = const StoresView().toJson()..remove('reads');
    expect(StoresView.fromJson(overTheWire(json)).reads, isEmpty);
  });

  test('one app told: its snapshot and state, merged into the view', () {
    final change = StoreAppChanged(
      app: app,
      read: null,
      snapshot: snapshot(t0),
      icon: StoreAppIcon(checkedAt: t0, url: 'https://example.com/i.png'),
    );
    final back =
        DataChange.fromJson(overTheWire(change.toJson()))! as StoreAppChanged;
    expect(back.app, app);
    expect(back.read, isNull);
    expect(back.snapshot!.rating.valueOrNull!.average, 4.2);
    expect(back.icon!.url, 'https://example.com/i.png');

    final before = StoresView(
      reads: {app.key: const StoreAppRead.reading()},
      refreshing: true,
    );
    final after = before.withApp(back);
    expect(after.reads, isEmpty);
    expect(after.apps.single.app, app);
    expect(after.icons[app.key]!.url, 'https://example.com/i.png');
    expect(after.refreshing, isTrue);

    // A newer reading of the same app replaces the older, never duplicates.
    final again = after.withApp(
      StoreAppChanged(
        app: app,
        snapshot: snapshot(t0.add(const Duration(minutes: 1))),
      ),
    );
    expect(again.apps, hasLength(1));
    expect(
      again.apps.single.releases.checkedAt,
      t0.add(const Duration(minutes: 1)),
    );
  });

  test('a state alone keeps what was read', () {
    final held = StoresView(apps: [snapshot(t0)]);
    final reading = held.withApp(
      const StoreAppChanged(app: app, read: StoreAppRead.reading()),
    );
    expect(reading.apps.single.app, app);
    expect(reading.reads[app.key]!.phase, StoreAppReadPhase.reading);
  });

  test('stores.refresh.app round-trips with the app it names', () {
    final read = DataEnvelope.readRequest(
      overTheWire(
        DataEnvelope.request(
          5,
          const StoresRefreshApp(
            store: StoreKind.googlePlay,
            id: 'com.example.one',
          ),
        ),
      ),
    );
    expect(read.refusal, isNull);
    final request = read.request! as StoresRefreshApp;
    expect(request.store, StoreKind.googlePlay);
    expect(request.id, 'com.example.one');
  });
}
