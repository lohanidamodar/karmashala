import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/stores/store_digest.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// The diff between two reads of one app, as pure values. Test data only.
void main() {
  final at = DateTime.utc(2026, 10, 9, 8);
  const apple = StoreApp(
    store: StoreKind.appStore,
    id: '1',
    bundleId: 'com.example.app',
    name: 'Example',
  );
  const play = StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.example.app',
    bundleId: 'com.example.app',
    name: 'Example',
  );

  StoreRelease release(
    String version,
    ReleaseState state,
    String raw, {
    String track = 'App Store',
    String? build,
    double? rollout,
  }) => StoreRelease(
    track: track,
    version: version,
    state: state,
    rawState: raw,
    build: build,
    rolloutFraction: rollout,
  );

  StoreReview review(String id, int rating, {int daysAgo = 0}) => StoreReview(
    id: id,
    rating: rating,
    body: 'Body $id',
    createdAt: at.subtract(Duration(days: daysAgo)),
  );

  StoreErrorIssue issue(String id, {String cause = 'StateError'}) =>
      StoreErrorIssue(
        id: id,
        kind: StoreErrorKind.crash,
        cause: cause,
        location: 'Main.run',
      );

  Reading<T> value<T>(T value) => ReadingValue(value, at);
  Reading<T> missing<T>() =>
      ReadingMissing(StoreFailure.network, 'The store did not answer.', at);

  StoreAppSnapshot snapshot({
    StoreApp app = apple,
    Reading<List<StoreRelease>>? releases,
    Reading<List<StoreReview>>? reviews,
    Reading<RatingSummary>? rating,
    Reading<VitalsSummary>? vitals,
    Reading<List<StoreErrorIssue>>? errors,
  }) => StoreAppSnapshot(
    app: app,
    releases: releases ?? value(const []),
    reviews: reviews ?? value(const []),
    rating: rating ?? value(const RatingSummary(average: 4.5, count: 10)),
    vitals: vitals ?? missing(),
    downloads: missing(),
    errorIssues: errors,
  );

  List<StoreChange> diff(StoreAppSnapshot before, StoreAppSnapshot after) =>
      storeChanges(
        after.app.store,
        StoreDigest.of(before),
        StoreDigest.of(after),
      );

  List<String> texts(List<StoreChange> changes) => [
    for (final change in changes) change.text,
  ];

  group('releases', () {
    test('an App Store version moving says both words', () {
      final changes = diff(
        snapshot(
          releases: value([
            release(
              '1.34.4',
              ReleaseState.pendingRelease,
              'PENDING_DEVELOPER_RELEASE',
              build: '70',
            ),
          ]),
        ),
        snapshot(
          releases: value([
            release('1.34.4', ReleaseState.live, 'READY_FOR_SALE', build: '71'),
          ]),
        ),
      );
      expect(texts(changes), ['1.34.4 Approved → Ready for sale']);
      expect(changes.single.kind, StoreChangeKind.release);
      expect(changes.single.attention, isFalse);
    });

    test('a rejection, metadata rejection or action needed wants a person', () {
      for (final (raw, state, words) in [
        ('REJECTED', ReleaseState.rejected, 'Rejected'),
        ('METADATA_REJECTED', ReleaseState.rejected, 'Metadata rejected'),
        (
          'DEVELOPER_ACTION_NEEDED',
          ReleaseState.unknown,
          'Developer action needed',
        ),
      ]) {
        final changes = diff(
          snapshot(
            releases: value([
              release('2.0', ReleaseState.inReview, 'IN_REVIEW'),
            ]),
          ),
          snapshot(releases: value([release('2.0', state, raw)])),
        );
        expect(texts(changes), ['2.0 In review → $words']);
        expect(changes.single.attention, isTrue, reason: raw);
      }
    });

    test('a new version appearing is told with its state', () {
      final changes = diff(
        snapshot(
          releases: value([
            release('1.0', ReleaseState.live, 'READY_FOR_SALE'),
          ]),
        ),
        snapshot(
          releases: value([
            release('1.0', ReleaseState.live, 'READY_FOR_SALE'),
            release('1.1', ReleaseState.waitingForReview, 'WAITING_FOR_REVIEW'),
          ]),
        ),
      );
      expect(texts(changes), ['New 1.1: Waiting for review']);
    });

    test('a Play rollout moving, and halting, says its share', () {
      final rolling = diff(
        snapshot(
          app: play,
          releases: value([
            release(
              '1.2',
              ReleaseState.rollingOut,
              'PUBLISHED',
              track: 'production',
              build: '12',
              rollout: 0.2,
            ),
          ]),
        ),
        snapshot(
          app: play,
          releases: value([
            release(
              '1.2',
              ReleaseState.rollingOut,
              'PUBLISHED',
              track: 'production',
              build: '12',
              rollout: 0.5,
            ),
          ]),
        ),
      );
      expect(texts(rolling), ['1.2 Rolling out 20% → Rolling out 50%']);
      expect(rolling.single.attention, isFalse);

      final halted = diff(
        snapshot(
          app: play,
          releases: value([
            release(
              '1.2',
              ReleaseState.rollingOut,
              'PUBLISHED',
              track: 'production',
              build: '12',
              rollout: 0.5,
            ),
          ]),
        ),
        snapshot(
          app: play,
          releases: value([
            release(
              '1.2',
              ReleaseState.halted,
              'HALTED',
              track: 'production',
              build: '12',
              rollout: 0.5,
            ),
          ]),
        ),
      );
      expect(texts(halted), ['1.2 Rolling out 50% → Halted 50%']);
      expect(halted.single.attention, isTrue);
    });

    test('a TestFlight build processed or failed is a build change', () {
      StoreRelease build(ReleaseState state, String raw) =>
          release('1.35.0', state, raw, track: 'TestFlight', build: '72');
      final processed = diff(
        snapshot(
          releases: value([build(ReleaseState.processing, 'PROCESSING')]),
        ),
        snapshot(releases: value([build(ReleaseState.testing, 'VALID')])),
      );
      expect(texts(processed), ['TestFlight 1.35.0 (72) processed']);
      expect(processed.single.kind, StoreChangeKind.build);
      expect(processed.single.attention, isFalse);

      final failed = diff(
        snapshot(
          releases: value([build(ReleaseState.processing, 'PROCESSING')]),
        ),
        snapshot(releases: value([build(ReleaseState.rejected, 'FAILED')])),
      );
      expect(texts(failed), ['TestFlight 1.35.0 (72) failed processing']);
      expect(failed.single.attention, isTrue);

      final arrived = diff(
        snapshot(releases: value(const [])),
        snapshot(
          releases: value([build(ReleaseState.processing, 'PROCESSING')]),
        ),
      );
      expect(texts(arrived), ['New TestFlight 1.35.0 (72) processing']);
    });

    test('a build attached to an App Store version is not a new release', () {
      final changes = diff(
        snapshot(
          releases: value([
            release('2.0', ReleaseState.draft, 'PREPARE_FOR_SUBMISSION'),
          ]),
        ),
        snapshot(
          releases: value([
            release(
              '2.0',
              ReleaseState.draft,
              'PREPARE_FOR_SUBMISSION',
              build: '80',
            ),
          ]),
        ),
      );
      expect(changes, isEmpty);
    });
  });

  group('reviews, rating, errors and stability', () {
    test('new reviews are counted with the lowest stars', () {
      final changes = diff(
        snapshot(reviews: value([review('a', 5, daysAgo: 2)])),
        snapshot(
          reviews: value([
            review('c', 2),
            review('b', 4),
            review('d', 5),
            review('a', 5, daysAgo: 2),
          ]),
        ),
      );
      expect(texts(changes), ['3 new reviews (lowest 2★)']);
      expect(changes.single.attention, isTrue);
    });

    test('one new kind review is not attention', () {
      final changes = diff(
        snapshot(reviews: value(const [])),
        snapshot(reviews: value([review('a', 4)])),
      );
      expect(texts(changes), ['1 new review (4★)']);
      expect(changes.single.attention, isFalse);
    });

    test('a review older than all known before is not new', () {
      final changes = diff(
        snapshot(reviews: value([review('a', 5, daysAgo: 2)])),
        snapshot(
          reviews: value([
            review('a', 5, daysAgo: 2),
            review('old', 1, daysAgo: 9),
          ]),
        ),
      );
      expect(changes, isEmpty);
    });

    test('the rating moving by 0.1 or more is told, less is not', () {
      Reading<RatingSummary> rated(double average) =>
          value(RatingSummary(average: average, count: 10));
      expect(
        texts(diff(snapshot(rating: rated(4.5)), snapshot(rating: rated(4.3)))),
        ['Rating 4.5 → 4.3'],
      );
      expect(
        diff(snapshot(rating: rated(4.5)), snapshot(rating: rated(4.45))),
        isEmpty,
      );
    });

    test('a crash cluster new and one gone are both told', () {
      final changes = diff(
        snapshot(app: play, errors: value([issue('old')])),
        snapshot(
          app: play,
          errors: value([issue('new', cause: 'NullPointerException')]),
        ),
      );
      expect(texts(changes), [
        'New crash: NullPointerException in Main.run',
        'No longer reported: crash: StateError in Main.run',
      ]);
      expect(changes.map((change) => change.kind), [
        StoreChangeKind.errorNew,
        StoreChangeKind.errorResolved,
      ]);
    });

    test('a crash rate that at least doubled past 1% wants a person', () {
      Reading<VitalsSummary> rate(double crash) => value(
        VitalsSummary(from: at, to: at, crashRate: crash, anrRate: 0.001),
      );
      final changes = diff(
        snapshot(app: play, vitals: rate(0.006)),
        snapshot(app: play, vitals: rate(0.013)),
      );
      expect(texts(changes), ['Crash rate 0.60% → 1.30%']);
      expect(changes.single.attention, isTrue);
      expect(
        diff(
          snapshot(app: play, vitals: rate(0.002)),
          snapshot(app: play, vitals: rate(0.005)),
        ),
        isEmpty,
        reason: 'doubled, but still low',
      );
    });
  });

  group('noise and first reads', () {
    test('the same read twice, in another order and later, says nothing', () {
      final first = snapshot(
        releases: value([
          release('1.0', ReleaseState.live, 'READY_FOR_SALE'),
          release('1.1', ReleaseState.inReview, 'IN_REVIEW'),
        ]),
        reviews: value([review('a', 3), review('b', 5)]),
      );
      final again = StoreAppSnapshot(
        app: apple,
        releases: ReadingValue([
          release('1.1', ReleaseState.inReview, 'IN_REVIEW'),
          release('1.0', ReleaseState.live, 'READY_FOR_SALE'),
        ], at.add(const Duration(hours: 3))),
        reviews: ReadingValue([
          review('b', 5),
          review('a', 3),
        ], at.add(const Duration(hours: 3))),
        rating: value(const RatingSummary(average: 4.5, count: 11)),
        vitals: missing(),
        downloads: missing(),
      );
      expect(diff(first, again), isEmpty);
    });

    test('a part never read before, or missed now, is not a change', () {
      final unread = snapshot(
        releases: missing(),
        reviews: missing(),
        rating: missing(),
      );
      final read = snapshot(
        releases: value([release('1.0', ReleaseState.rejected, 'REJECTED')]),
        reviews: value([review('a', 1)]),
        rating: value(const RatingSummary(average: 2)),
      );
      expect(diff(unread, read), isEmpty);
      expect(diff(read, unread), isEmpty);
    });

    test('a part a read missed keeps what it held for the next one', () {
      final before = StoreDigest.of(
        snapshot(
          releases: value([release('1.0', ReleaseState.inReview, 'IN_REVIEW')]),
        ),
      );
      final merged = before.mergedWith(
        StoreDigest.of(snapshot(releases: missing())),
      );
      final after = StoreDigest.of(
        snapshot(
          releases: value([release('1.0', ReleaseState.rejected, 'REJECTED')]),
        ),
      );
      expect(texts(storeChanges(StoreKind.appStore, merged, after)), [
        '1.0 In review → Rejected',
      ]);
    });

    test('moving into Expired or Replaced is the store tidying up', () {
      final changes = diff(
        snapshot(
          releases: value([
            release(
              '1.0',
              ReleaseState.testing,
              'VALID',
              track: 'TestFlight',
              build: '5',
            ),
          ]),
        ),
        snapshot(
          releases: value([
            release(
              '1.0',
              ReleaseState.expired,
              'EXPIRED',
              track: 'TestFlight',
              build: '5',
            ),
          ]),
        ),
      );
      expect(changes, isEmpty);
    });

    test('a digest survives its JSON whole', () {
      final digest = StoreDigest.of(
        snapshot(
          app: play,
          releases: value([
            release(
              '1.2',
              ReleaseState.rollingOut,
              'PUBLISHED',
              track: 'production',
              build: '12',
              rollout: 0.2,
            ),
          ]),
          reviews: value([review('a', 2)]),
          vitals: value(
            VitalsSummary(from: at, to: at, crashRate: 0.01, anrRate: 0.002),
          ),
          errors: value([issue('e1')]),
        ),
      );
      final back = StoreDigest.fromJson(digest.toJson());
      expect(storeChanges(StoreKind.googlePlay, digest, back), isEmpty);
      expect(back.toJson(), digest.toJson());
    });
  });

  test('the platform is read off the App Store tracks', () {
    expect(storePlatform(snapshot(app: play)), 'Android');
    expect(storePlatform(snapshot()), 'iOS');
    expect(
      storePlatform(
        snapshot(
          releases: value([
            release(
              '1.0',
              ReleaseState.live,
              'READY_FOR_SALE',
              track: 'App Store (macOS)',
            ),
          ]),
        ),
      ),
      'macOS',
    );
  });
}
