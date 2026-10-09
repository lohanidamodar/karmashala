import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/stores/server_store_desk.dart';
import 'package:karmashala_host/src/stores/store_history.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// What the server keeps of each app over time: a row a day, release steps,
/// retention, and unknowns kept unknown. A fake clock and scripted fake
/// stores; no store is ever called. Test values only.
void main() {
  const app = StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.example.one',
    bundleId: 'com.example.one',
    name: 'One',
  );
  final day0 = DateTime.utc(2026, 10, 1, 9);

  StoreAppSnapshot snapshot({
    required DateTime at,
    double? rating,
    int? ratingCount,
    double? crashRate,
    double? anrRate,
    List<StoreReview>? reviews,
    DownloadSeries? downloads,
    List<StoreRelease>? releases,
  }) => StoreAppSnapshot(
    app: app,
    releases: releases == null
        ? ReadingMissing(StoreFailure.network, 'Offline.', at)
        : ReadingValue(releases, at),
    reviews: reviews == null
        ? ReadingMissing(StoreFailure.network, 'Offline.', at)
        : ReadingValue(reviews, at),
    rating: rating == null
        ? ReadingMissing(StoreFailure.network, 'Offline.', at)
        : ReadingValue(RatingSummary(average: rating, count: ratingCount), at),
    vitals: crashRate == null && anrRate == null
        ? ReadingMissing(StoreFailure.notSupported, 'Not here.', at)
        : ReadingValue(
            VitalsSummary(
              from: at.subtract(const Duration(days: 28)),
              to: at,
              crashRate: crashRate,
              anrRate: anrRate,
            ),
            at,
          ),
    downloads: downloads == null
        ? ReadingMissing(StoreFailure.notConfigured, 'Not set up.', at)
        : ReadingValue(downloads, at),
  );

  StoreRelease release(
    String version,
    ReleaseState state,
    String raw, {
    double? rollout,
    String track = 'production',
  }) => StoreRelease(
    track: track,
    version: version,
    build: '7',
    state: state,
    rawState: raw,
    rolloutFraction: rollout,
  );

  group('StoreHistoryBook', () {
    test('keeps one row a day; a later read that day fills it in', () {
      final book = StoreHistoryBook()
        ..record(snapshot(at: day0, rating: 4.4, ratingCount: 90), day0)
        ..record(
          snapshot(at: day0, crashRate: 0.01, anrRate: 0.002),
          day0.add(const Duration(hours: 3)),
        );
      final days = book.view(days: 30, now: day0).of(app.key)!.days;
      expect(days, hasLength(1));
      expect(days.single.day, DateTime.utc(2026, 10, 1));
      expect(days.single.rating, 4.4);
      expect(days.single.ratingCount, 90);
      expect(days.single.crashRate, 0.01);
      expect(days.single.anrRate, 0.002);
    });

    test('a part no read said stays unknown, never zero', () {
      final book = StoreHistoryBook()
        ..record(snapshot(at: day0, rating: 4.4), day0);
      final day = book.view(days: 30, now: day0).of(app.key)!.days.single;
      expect(day.crashRate, isNull);
      expect(day.anrRate, isNull);
      expect(day.installs, isNull);
      expect(day.reviews, isNull);
      expect(day.ratingCount, isNull);
    });

    test('a failed read adds no day at all', () {
      final book = StoreHistoryBook()..record(snapshot(at: day0), day0);
      expect(book.view(days: 30, now: day0).of(app.key)!.days, isEmpty);
    });

    test('counts reviews per day over the days the page covers', () {
      StoreReview review(String id, DateTime at) =>
          StoreReview(id: id, rating: 5, body: 'b', createdAt: at);
      final book = StoreHistoryBook()
        ..record(
          snapshot(
            at: day0,
            reviews: [
              review('a', day0),
              review('b', day0.subtract(const Duration(hours: 2))),
              review('c', day0.subtract(const Duration(days: 2))),
            ],
          ),
          day0,
        );
      final days = book.view(days: 30, now: day0).of(app.key)!.days;
      expect(
        {for (final d in days) storeDayKey(d.day): d.reviews},
        {
          '2026-09-29': 1,
          // Covered, and none was written: a zero, not a gap.
          '2026-09-30': 0,
          '2026-10-01': 2,
        },
      );
      // A later page that has lost the oldest never lowers a day's count.
      book.record(
        snapshot(at: day0, reviews: [review('a', day0)]),
        day0.add(const Duration(hours: 1)),
      );
      final again = book.view(days: 30, now: day0).of(app.key)!.days;
      expect(again.last.reviews, 2);
      expect(again.first.reviews, 1);
    });

    test('installs go on the day the store reported them for', () {
      final book = StoreHistoryBook()
        ..record(
          snapshot(
            at: day0,
            downloads: DownloadSeries(
              unit: 'Installs',
              days: [
                DailyCount(DateTime.utc(2026, 9, 28), 12),
                DailyCount(DateTime.utc(2026, 9, 29), 15),
              ],
            ),
          ),
          day0,
        );
      final days = book.view(days: 30, now: day0).of(app.key)!.days;
      expect([for (final d in days) d.installs], [12, 15]);
      expect(days.last.day, DateTime.utc(2026, 9, 29));
    });

    test('drops days older than a year', () {
      final book = StoreHistoryBook()
        ..record(snapshot(at: day0, rating: 4.0), day0);
      final later = day0.add(const Duration(days: kStoreHistoryDays + 2));
      book.record(snapshot(at: later, rating: 4.2), later);
      final days = book.view(days: kStoreHistoryDays, now: later);
      expect(days.of(app.key)!.days.map((d) => d.rating), [4.2]);
    });

    test('a view asks for the last N days only', () {
      final book = StoreHistoryBook();
      for (var i = 0; i < 40; i++) {
        final at = day0.add(Duration(days: i));
        book.record(snapshot(at: at, rating: 4.0), at);
      }
      final now = day0.add(const Duration(days: 39));
      expect(book.view(days: 30, now: now).of(app.key)!.days, hasLength(30));
      expect(book.view(days: 90, now: now).of(app.key)!.days, hasLength(40));
    });

    test('a release is stepped as its state or rollout moves', () {
      final book = StoreHistoryBook();
      void read(Duration after, List<StoreRelease> releases) {
        final at = day0.add(after);
        book.record(snapshot(at: at, releases: releases), at);
      }

      read(Duration.zero, [
        release('2.0', ReleaseState.inReview, 'inProgress'),
        // Finished before it was ever read: not a step.
        release('1.0', ReleaseState.superseded, 'completed'),
      ]);
      read(const Duration(hours: 5), [
        release('2.0', ReleaseState.inReview, 'inProgress'),
      ]);
      read(const Duration(hours: 9), [
        release('2.0', ReleaseState.rollingOut, 'inProgress', rollout: 0.2),
      ]);
      read(const Duration(days: 2), [
        release('2.0', ReleaseState.rollingOut, 'inProgress', rollout: 0.5),
      ]);
      read(const Duration(days: 3), [
        release('2.0', ReleaseState.live, 'completed'),
      ]);
      final steps = book.view(days: 30, now: day0).of(app.key)!.steps;
      expect(steps.map((s) => s.words), [
        'In review',
        'Rolling out 20%',
        'Rolling out 50%',
        'Live',
      ]);
      expect(steps.first.firstRead, isTrue);
      expect(steps.skip(1).every((s) => !s.firstRead), isTrue);
      expect(steps[1].at, day0.add(const Duration(hours: 9)));
    });

    test('round-trips through JSON', () {
      final book = StoreHistoryBook()
        ..record(
          snapshot(
            at: day0,
            rating: 4.1,
            releases: [release('2.0', ReleaseState.live, 'completed')],
          ),
          day0,
        );
      final again = StoreHistoryBook.fromJson(
        (jsonDecode(jsonEncode(book.toJson())) as Map).cast<String, Object?>(),
      );
      final held = again.view(days: 30, now: day0).of(app.key)!;
      expect(held.days.single.rating, 4.1);
      expect(held.steps.single.words, 'Live');
    });
  });

  group('the desk keeps history', () {
    late Directory tmp;
    late AppDatabase database;
    late DataService data;
    late DataSession client;
    late ServerStoreDesk desk;
    late _Store play;
    late DateTime now;

    const apple = StoreApp(
      store: StoreKind.appStore,
      id: '1',
      bundleId: 'com.example.ios',
      name: 'Ios',
    );
    const pem =
        '-----BEGIN PRIVATE KEY-----\nnot-a-real-key-r83\n-----END PRIVATE KEY-----';

    ServerStoreDesk open() {
      final opened = ServerStoreDesk(
        dataDirectory: tmp.path,
        tell: data.announce,
        clock: () => now,
        appleClient: (_) => play,
        timer: (wait, fire) => _NoTimer(),
        random: _NoJitter(),
      );
      data.storeWork = opened;
      return opened;
    }

    Future<R> ask<R>(DataRequest<R> request) async =>
        (await client.handleLater(request)).value;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('ks-store-history-');
      database = AppDatabase.memory();
      data = DataService(database);
      now = DateTime.utc(2026, 10, 1, 8);
      play = _Store([apple]);
      desk = open();
      client = data.open((_) {});
      await ask(
        const StoreAppleSet(
          keyId: 'KEY123',
          issuerId: 'issuer-1',
          privateKeyPem: pem,
        ),
      );
      await desk.refresh();
    });

    tearDown(() {
      desk.close();
      database.close();
      tmp.deleteSync(recursive: true);
    });

    test('a read a day is a row a day, kept beside changes.json', () async {
      for (final (i, rating) in [4.0, 4.1, 4.3].indexed) {
        play.average = rating;
        now = DateTime.utc(2026, 10, 2 + i, 8);
        await desk.refresh();
      }
      final history = await ask(
        StoresHistoryGet(appKeys: [apple.key], days: 30),
      );
      expect(history.keptDays, kStoreHistoryDays);
      final days = history.of(apple.key)!.days;
      expect(days.map((d) => d.rating), [4.5, 4.0, 4.1, 4.3]);
      // The App Store gives no crash rate: unknown, not zero.
      expect(days.every((d) => d.crashRate == null), isTrue);

      final file = File(
        p.join(tmp.path, 'stores', ServerStoreDesk.historyFileName),
      );
      expect(file.existsSync(), isTrue);
      expect(
        File(
          p.join(tmp.path, 'stores', ServerStoreDesk.watchFileName),
        ).existsSync(),
        isTrue,
      );

      // It outlives a restart.
      desk.close();
      desk = open();
      final kept = await desk.history(const StoresHistoryGet(days: 30));
      expect(kept.of(apple.key)!.days, hasLength(4));
    });

    test('a removed credential takes its history with it', () async {
      await ask(const StoreCredentialRemove(StoreKind.appStore));
      final history = await ask(const StoresHistoryGet());
      expect(history.apps, isEmpty);
    });
  });
}

class _Store implements StoreClient {
  _Store(this.apps);

  @override
  StoreKind get store => StoreKind.appStore;
  final List<StoreApp> apps;
  double average = 4.5;

  @override
  Future<List<StoreApp>> listApps() async => apps;

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async => const [];

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async => const [];

  @override
  Future<RatingSummary> rating(StoreApp app) async =>
      RatingSummary(average: average, count: 10);

  @override
  Future<VitalsSummary> vitals(StoreApp app) =>
      throw const StoreException(StoreFailure.notSupported, 'Not here.');

  @override
  Future<DownloadSeries> downloads(StoreApp app) =>
      throw const StoreException(StoreFailure.notConfigured, 'Not set up.');

  @override
  Future<StoreIconImage?> icon(StoreApp app) async => null;

  @override
  void close() {}
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

class _NoJitter implements math.Random {
  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;

  @override
  int nextInt(int max) => 0;
}
