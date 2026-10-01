import 'dart:convert';

import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

const _app = StoreApp(
  store: StoreKind.googlePlay,
  id: 'com.example.app',
  bundleId: 'com.example.app',
  name: 'Example',
);

class _FakeClient implements StoreClient {
  _FakeClient({this.failRating = false, this.throwOddly = false});

  final bool failRating;
  final bool throwOddly;
  bool closed = false;

  @override
  StoreKind get store => StoreKind.googlePlay;

  @override
  Future<List<StoreApp>> listApps() async => const [_app];

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async => [
    const StoreRelease(
      track: 'internal',
      version: '2.1.0',
      state: ReleaseState.testing,
      rawState: 'completed',
    ),
    const StoreRelease(
      track: 'production',
      version: '2.0.0',
      build: '41',
      state: ReleaseState.rollingOut,
      rawState: 'inProgress',
      rolloutFraction: 0.2,
    ),
  ];

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async => [
    StoreReview(
      id: 'r1',
      rating: 4,
      body: 'Good',
      createdAt: DateTime.utc(2026, 9, 29),
      reply: 'Thanks',
      repliedAt: DateTime.utc(2026, 9, 30),
    ),
  ];

  @override
  Future<RatingSummary> rating(StoreApp app) async {
    if (throwOddly) throw StateError('boom');
    if (failRating) {
      throw const StoreException(StoreFailure.notConfigured, 'Add the bucket.');
    }
    return const RatingSummary(average: 4.5, count: 120);
  }

  @override
  Future<VitalsSummary> vitals(StoreApp app) async => VitalsSummary(
    from: DateTime.utc(2026, 9, 1),
    to: DateTime.utc(2026, 9, 28),
    crashRate: 0.004,
  );

  @override
  Future<DownloadSeries> downloads(StoreApp app) async => DownloadSeries(
    unit: 'Installs',
    days: [
      DailyCount(DateTime.utc(2026, 9, 27), 10),
      DailyCount(DateTime.utc(2026, 9, 28), 12),
    ],
  );

  @override
  Future<StoreIconImage?> icon(StoreApp app) async => null;

  @override
  void close() => closed = true;
}

void main() {
  final now = DateTime.utc(2026, 9, 30, 12);

  test('a failed reading leaves the app\'s other readings standing', () async {
    final console = StoreConsole([
      _FakeClient(failRating: true),
    ], now: () => now);

    final snapshot = await console.snapshot(_app);

    final rating = snapshot.rating as ReadingMissing<RatingSummary>;
    expect(rating.kind, StoreFailure.notConfigured);
    expect(rating.expected, isTrue);
    expect(rating.checkedAt, now);
    expect(snapshot.releases.valueOrNull, hasLength(2));
    expect(snapshot.downloads.valueOrNull!.total, 22);
  });

  test('an error that is not a StoreException is a shape failure', () async {
    final console = StoreConsole([
      _FakeClient(throwOddly: true),
    ], now: () => now);

    final snapshot = await console.snapshot(_app);

    final rating = snapshot.rating as ReadingMissing<RatingSummary>;
    expect(rating.kind, StoreFailure.shape);
    expect(rating.message, isNot(contains('boom')));
  });

  test('live is the first live or rolling-out release', () async {
    final console = StoreConsole([_FakeClient()], now: () => now);

    final snapshot = await console.snapshot(_app);

    expect(snapshot.live!.track, 'production');
    expect(snapshot.pending.single.rolloutFraction, 0.2);
  });

  test('a snapshot survives JSON, missing readings included', () async {
    final console = StoreConsole([
      _FakeClient(failRating: true),
    ], now: () => now);
    final snapshot = await console.snapshot(_app);

    final decoded = StoreAppSnapshot.fromJson(
      (jsonDecode(jsonEncode(snapshot.toJson())) as Map)
          .cast<String, Object?>(),
    );

    expect(decoded.app, _app);
    expect(decoded.releases.valueOrNull!.last.build, '41');
    expect(decoded.reviews.valueOrNull!.single.answered, isTrue);
    expect(decoded.rating, isA<ReadingMissing<RatingSummary>>());
    expect(decoded.vitals.valueOrNull!.anrRate, isNull);
    expect(
      decoded.downloads.valueOrNull!.days.first.day,
      DateTime.utc(2026, 9, 27),
    );
    expect(decoded.downloads.checkedAt, now);
  });

  test('listApps reports each store by itself', () async {
    final console = StoreConsole([_FakeClient()], now: () => now);

    final readings = await console.listApps();

    expect(readings.single.store, StoreKind.googlePlay);
    expect(readings.single.apps.valueOrNull, const [_app]);
  });

  test('a rejection a newer live release overtook is not pending', () {
    StoreAppSnapshot withReleases(List<StoreRelease> releases) =>
        StoreAppSnapshot(
          app: _app,
          releases: ReadingValue(releases, now),
          reviews: ReadingValue(const [], now),
          rating: ReadingValue(const RatingSummary(average: 4), now),
          vitals: ReadingMissing(StoreFailure.notSupported, '', now),
          downloads: ReadingMissing(StoreFailure.notSupported, '', now),
        );
    const live = StoreRelease(
      track: 'production',
      version: '1.1',
      build: '20',
      state: ReleaseState.live,
      rawState: '',
    );
    const old = StoreRelease(
      track: 'production',
      version: '1.0',
      build: '10',
      state: ReleaseState.rejected,
      rawState: '',
    );
    const next = StoreRelease(
      track: 'production',
      version: '1.2',
      build: '30',
      state: ReleaseState.rejected,
      rawState: '',
    );
    expect(withReleases([live, old]).pending, isEmpty);
    expect(withReleases([live, old, next]).pending, [next]);
  });

  test('a rating carries its history and says its trend', () {
    var rating = const RatingSummary(average: 4.0);
    for (var day = 1; day <= 9; day++) {
      rating = RatingSummary(
        average: 4.0 + day / 100,
      ).carriedFrom(rating, DateTime.utc(2026, 9, day, 10));
    }
    expect(rating.history, hasLength(9));
    final trend = rating.trend!;
    expect(trend.since, DateTime.utc(2026, 9, 2));
    expect(trend.change, closeTo(0.07, 1e-9));

    final first = const RatingSummary(
      average: 4.2,
    ).carriedFrom(null, DateTime.utc(2026, 9, 1));
    expect(first.trend, isNull);
  });

  test('close closes every client', () {
    final client = _FakeClient();
    StoreConsole([client]).close();
    expect(client.closed, isTrue);
  });

  group('all-time installs', () {
    test('a store that counts none leaves the reading null', () async {
      final snapshot = await StoreConsole([
        _FakeClient(),
      ], now: () => now).snapshot(_app);
      expect(snapshot.allTimeInstalls, isNull);
      expect(snapshot.toJson().containsKey('allTimeInstalls'), isFalse);
    });

    test('a store that counts them is read, and survives JSON', () async {
      final snapshot = await StoreConsole([
        _InstallsClient(),
      ], now: () => now).snapshot(_app);
      final back = StoreAppSnapshot.fromJson(
        (jsonDecode(jsonEncode(snapshot.toJson())) as Map)
            .cast<String, Object?>(),
      );
      final total = back.allTimeInstalls!.valueOrNull!;
      expect(total.count, 1234);
      expect(total.measure, 'user installs');
      expect(total.since, '2024-03');
      expect(total.through, DateTime.utc(2026, 9, 29));
      expect(total.atLeast, isFalse);
    });

    test('a reading from before it existed reads as null', () async {
      final snapshot = await StoreConsole([
        _FakeClient(),
      ], now: () => now).snapshot(_app);
      final json = snapshot.toJson()..remove('allTimeInstalls');
      expect(StoreAppSnapshot.fromJson(json).allTimeInstalls, isNull);
    });

    test('a listing band is a floor', () {
      final band = InstallTotal.fromBand('10K+', note: 'No bucket.')!;
      expect(band.count, 10000);
      expect(band.atLeast, isTrue);
      expect(band.band, '10K+');
      expect(InstallTotal.fromJson(band.toJson()).note, 'No bucket.');
      expect(installBandFloor('1.5M+'), 1500000);
      expect(installBandFloor('10,000+'), 10000);
      expect(installBandFloor('500+'), 500);
      expect(installBandFloor('1 B+'), 1000000000);
      expect(installBandFloor('Downloads'), isNull);
      expect(InstallTotal.fromBand('viele'), isNull);
    });

    test('listing wraps a plain icon for a store without a page', () async {
      final reading = await StoreConsole([
        _FakeClient(),
      ], now: () => now).listing(_app);
      expect(reading, isA<ReadingValue<StoreListing?>>());
      expect(reading.valueOrNull, isNull);
    });
  });
}

class _InstallsClient extends _FakeClient implements StoreInstallTotalSource {
  @override
  Future<InstallTotal> allTimeInstalls(StoreApp app) async => InstallTotal(
    count: 1234,
    measure: 'user installs',
    source: InstallTotalSource.reports,
    since: '2024-03',
    through: DateTime.utc(2026, 9, 29),
  );
}
