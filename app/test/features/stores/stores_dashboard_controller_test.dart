import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_credentials.dart';
import 'package:karmashala/src/features/stores/application/stores_dashboard.dart';
import 'package:karmashala/src/features/stores/data/store_snapshot_store.dart';
import 'package:riverpod/riverpod.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';

class _Credentials extends StoreCredentialsController {
  _Credentials(this._credentials);

  final StoreCredentials _credentials;

  @override
  Future<StoreCredentials> build() async => _credentials;
}

/// A store that lists [apps], or refuses with [failure], and counts how many
/// readings are in flight at once.
class _Store implements StoreClient {
  _Store(this.store, this.apps, {this.failure});

  @override
  final StoreKind store;
  final List<StoreApp> apps;
  final StoreException? failure;

  int lists = 0;
  int inFlight = 0;
  int mostInFlight = 0;

  @override
  Future<List<StoreApp>> listApps() async {
    lists++;
    if (failure case final failure?) throw failure;
    return apps;
  }

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async {
    inFlight++;
    mostInFlight = math.max(mostInFlight, inFlight);
    await Future<void>.delayed(Duration.zero);
    inFlight--;
    return [storeRelease(ReleaseState.live)];
  }

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async => const [];

  @override
  Future<RatingSummary> rating(StoreApp app) async =>
      const RatingSummary(average: 4.2);

  @override
  Future<VitalsSummary> vitals(StoreApp app) async =>
      throw const StoreException(
        StoreFailure.notSupported,
        'This store publishes no crash rate.',
      );

  @override
  Future<DownloadSeries> downloads(StoreApp app) async =>
      const DownloadSeries(unit: 'Units', days: []);

  @override
  void close() {}
}

void main() {
  // Not keys: text the import forms would refuse.
  const credentials = StoreCredentials(
    apple: AppleApiKey(
      keyId: 'KEYID',
      issuerId: 'issuer',
      privateKeyPem: 'placeholder',
    ),
    play: PlayAccount(serviceAccountJson: '{}'),
  );
  final now = DateTime.utc(2026, 9, 30, 9);

  late Directory directory;
  late StoreSnapshotStore file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('stores_dashboard_test');
    file = StoreSnapshotStore(() async => directory);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  ProviderContainer container(
    List<StoreClient> clients, {
    StoreCredentials credentials = credentials,
  }) {
    final container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(now)),
        storeCredentialsProvider.overrideWith(() => _Credentials(credentials)),
        storeSnapshotStoreProvider.overrideWithValue(file),
        storeConsoleProvider.overrideWithValue(
          StoreConsole(clients, now: () => now),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('without a credential nothing is read, kept file or not', () async {
    final app = storeApp(StoreKind.appStore, 'com.example.notes');
    await file.write(
      StoreSnapshotFile(savedAt: now, apps: [storeSnapshot(app)]),
    );
    final store = _Store(StoreKind.appStore, [app]);
    final c = container([store], credentials: const StoreCredentials());

    final dashboard = await c.read(storesDashboardProvider.future);
    await c.read(storesDashboardProvider.notifier).refreshIfStale();

    expect(dashboard.groups, isEmpty);
    expect(store.lists, 0);
  });

  test(
    'the kept file is shown at once, and a fresh one is not read again',
    () async {
      final app = storeApp(StoreKind.appStore, 'com.example.notes');
      final savedAt = now.subtract(const Duration(minutes: 10));
      await file.write(
        StoreSnapshotFile(savedAt: savedAt, apps: [storeSnapshot(app)]),
      );
      final store = _Store(StoreKind.appStore, [app]);
      final c = container([store]);

      final dashboard = await c.read(storesDashboardProvider.future);
      expect(dashboard.refreshedAt, savedAt);
      expect(dashboard.groups.single.entries.single.snapshot, isNotNull);

      await c.read(storesDashboardProvider.notifier).refreshIfStale();
      expect(store.lists, 0);
    },
  );

  test('a stale file is read again when the tab opens', () async {
    final app = storeApp(StoreKind.appStore, 'com.example.notes');
    await file.write(
      StoreSnapshotFile(
        savedAt: now.subtract(const Duration(minutes: 31)),
        apps: [storeSnapshot(app)],
      ),
    );
    final store = _Store(StoreKind.appStore, [app]);
    final c = container([store]);

    await c.read(storesDashboardProvider.future);
    await c.read(storesDashboardProvider.notifier).refreshIfStale();

    expect(store.lists, 1);
    expect(c.read(storesDashboardProvider).value?.refreshedAt, now);
  });

  test(
    'refresh reads every app, four at a time, and keeps the result',
    () async {
      final apps = [
        for (var i = 0; i < 9; i++)
          storeApp(StoreKind.appStore, 'com.example.a$i'),
      ];
      final apple = _Store(StoreKind.appStore, apps);
      final play = _Store(
        StoreKind.googlePlay,
        const [],
        failure: const StoreException(
          StoreFailure.permission,
          'The service account may not see this.',
        ),
      );
      final c = container([apple, play]);

      await c.read(storesDashboardProvider.future);
      await c.read(storesDashboardProvider.notifier).refresh();

      final dashboard = c.read(storesDashboardProvider).value!;
      expect(dashboard.refreshing, isFalse);
      expect(dashboard.done, 9);
      expect(dashboard.total, 9);
      expect(dashboard.refreshedAt, now);
      expect(dashboard.snapshots, hasLength(9));
      expect(apple.mostInFlight, kStoreRefreshConcurrency);
      // The store that failed says why, and takes nothing else with it.
      final failed =
          dashboard.stores[StoreKind.googlePlay]!
              as ReadingMissing<List<StoreApp>>;
      expect(failed.message, 'The service account may not see this.');

      final kept = (await file.read())!;
      expect(kept.savedAt, now);
      expect(kept.apps, hasLength(9));
    },
  );

  test('when no store answers, what is shown keeps its age', () async {
    final app = storeApp(StoreKind.appStore, 'com.example.notes');
    final savedAt = now.subtract(const Duration(hours: 2));
    await file.write(
      StoreSnapshotFile(savedAt: savedAt, apps: [storeSnapshot(app)]),
    );
    final apple = _Store(
      StoreKind.appStore,
      const [],
      failure: const StoreException(StoreFailure.network, 'No network.'),
    );
    final c = container([apple]);

    await c.read(storesDashboardProvider.future);
    await c.read(storesDashboardProvider.notifier).refresh();

    final dashboard = c.read(storesDashboardProvider).value!;
    expect(dashboard.refreshedAt, savedAt);
    expect(dashboard.refreshing, isFalse);
    // The app read before is still on screen, under the notice.
    expect(dashboard.groups.single.bundleId, 'com.example.notes');
    expect((await file.read())!.savedAt, savedAt);
  });
}
