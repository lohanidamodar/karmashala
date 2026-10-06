@Tags(['live-timing'])
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/stores/server_store_desk.dart';
import 'package:karmashala_store/database.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// How long a Stores refresh takes to show its first app and to finish, over
/// fake stores whose calls take what the real ones' requests add up to. Real
/// timers, so not a gate: run it deliberately and read what it prints.
///   dart test --tags=live-timing test/stores/store_refresh_timing_test.dart
void main() {
  test('cold and warm refresh, eight apps, one slow', () async {
    final tmp = Directory.systemTemp.createTempSync('ks-store-timing-');
    final database = AppDatabase.memory();
    addTearDown(() {
      database.close();
      tmp.deleteSync(recursive: true);
    });
    final data = DataService(database);

    // Connected once with stores that answer at once, so the timed runs below
    // start from held credentials and nothing read.
    var setup = ServerStoreDesk(
      dataDirectory: tmp.path,
      tell: data.announce,
      appleClient: (_) => LatentStoreClient(StoreKind.appStore, const []),
      playClient: (_) => LatentStoreClient(StoreKind.googlePlay, const []),
    );
    data.storeWork = setup;
    final session = data.open((_) {});
    await session.handleLater(
      const StoreAppleSet(
        keyId: 'KEY123',
        issuerId: 'issuer-1',
        privateKeyPem:
            '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----',
      ),
    );
    await session.handleLater(
      const StorePlaySet(
        serviceAccountJson:
            '{"type":"service_account","private_key":"not-a-real-play-key",'
            '"client_email":"bot@example.iam.gserviceaccount.com"}',
      ),
    );
    await setup.refresh();
    setup.close();
    final snapshot = File('${tmp.path}/stores/snapshot.json');
    if (snapshot.existsSync()) snapshot.deleteSync();

    Future<Run> timed(String name) async {
      final clock = Stopwatch()..start();
      final shown = <String>{};
      Duration? firstApp;
      late final ServerStoreDesk desk;
      void see(Iterable<String> keys) {
        shown.addAll(keys);
        if (shown.isNotEmpty) firstApp ??= clock.elapsed;
      }

      desk = ServerStoreDesk(
        dataDirectory: tmp.path,
        tell: (changes) {
          for (final change in changes) {
            switch (change) {
              case StoresChanged(:final view):
                see(view.apps.map((app) => app.app.key));
              default:
                see(appKeysTold(change));
            }
          }
        },
        appleClient: (_) =>
            LatentStoreClient(StoreKind.appStore, appleApps, scale: scale),
        playClient: (_) =>
            LatentStoreClient(StoreKind.googlePlay, playApps, scale: scale),
      );
      // What a client opening the tab is answered at once.
      see(desk.view.apps.map((app) => app.app.key));
      final opened = clock.elapsed;
      await desk.refresh();
      final loaded = clock.elapsed;
      desk.close();
      return Run(name, opened, firstApp, loaded, desk.view.apps.length);
    }

    final cold = await timed('cold (nothing kept)');
    final warm = await timed('warm (snapshot kept)');
    for (final run in [cold, warm]) {
      // ignore: avoid_print
      print(run);
    }
    expect(cold.apps, appleApps.length + playApps.length);
  });
}

/// The fake's milliseconds are multiplied by this, so the run is short; what
/// is printed is divided by it again.
const double scale = 0.2;

final appleApps = [
  for (final id in ['1', '2', '3'])
    StoreApp(
      store: StoreKind.appStore,
      id: id,
      bundleId: 'com.example.a$id',
      name: 'Apple $id',
    ),
];

final playApps = [
  for (final id in ['one', 'two', 'three', 'four', 'slow'])
    StoreApp(
      store: StoreKind.googlePlay,
      id: 'com.example.$id',
      bundleId: 'com.example.$id',
      name: 'Play $id',
    ),
];

/// The app keys a change other than [StoresChanged] makes visible; none
/// before the desk tells apps one at a time.
Iterable<String> appKeysTold(DataChange change) => const [];

class Run {
  Run(this.name, this.opened, this.firstApp, this.loaded, this.apps);

  final String name;
  final Duration opened;
  final Duration? firstApp;
  final Duration loaded;
  final int apps;

  static String _ms(Duration? d) =>
      d == null ? 'never' : '${(d.inMicroseconds / 1000 / scale).round()} ms';

  @override
  String toString() =>
      '$name: view answered ${_ms(opened)}, first app shown '
      '${_ms(firstApp)}, fully loaded ${_ms(loaded)}, $apps apps';
}

/// A store whose calls take as long as the real client's requests add up to
/// (one request ≈ 300–600 ms; sequential ones summed, parallel ones the
/// longest). Play's first call waits once for the OAuth token, as
/// `PlayAuth.client()` does per client.
class LatentStoreClient implements StoreClient {
  LatentStoreClient(this.store, this.apps, {this.scale = 0});

  @override
  final StoreKind store;
  final List<StoreApp> apps;
  final double scale;
  Future<void>? _token;

  bool get _play => store == StoreKind.googlePlay;

  Future<void> _take(int ms, {bool auth = true}) async {
    if (auth && _play) await (_token ??= _wait(300));
    await _wait(ms);
  }

  Future<void> _wait(int ms) =>
      Future.delayed(Duration(microseconds: (ms * 1000 * scale).round()));

  bool _slow(StoreApp app) => app.id.endsWith('slow');

  @override
  Future<List<StoreApp>> listApps() async {
    await _take(_play ? 400 : 500);
    return apps;
  }

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async {
    await _take(_play ? 350 : 600);
    return const [
      StoreRelease(
        track: 'production',
        version: '1.0.0',
        state: ReleaseState.live,
        rawState: 'LIVE',
      ),
    ];
  }

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async {
    await _take(_play ? 400 : 500);
    return const [];
  }

  @override
  Future<RatingSummary> rating(StoreApp app) async {
    await _take(300, auth: _play);
    return const RatingSummary(average: 4.5, count: 10);
  }

  @override
  Future<VitalsSummary> vitals(StoreApp app) async {
    if (!_play) {
      throw const StoreException(StoreFailure.notSupported, 'Not here.');
    }
    // Two metrics at once, each a freshness read then a query; the slow app
    // stands for one whose reporting call hangs until it is given up on.
    await _take(_slow(app) ? 8000 : 800);
    return VitalsSummary(
      from: DateTime.utc(2026, 9, 1),
      to: DateTime.utc(2026, 9, 28),
    );
  }

  @override
  Future<DownloadSeries> downloads(StoreApp app) async {
    await _take(_play ? 600 : 900);
    return const DownloadSeries(unit: 'Downloads', days: []);
  }

  @override
  Future<StoreIconImage?> icon(StoreApp app) async {
    // Play reads its public page and the image; Apple up to three lookups.
    await _take(_play ? 800 : 900, auth: false);
    return null;
  }

  @override
  void close() {}
}
