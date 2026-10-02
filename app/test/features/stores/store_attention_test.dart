import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/stores/application/store_attention.dart';
import 'package:store_console/store_console.dart';

import 'store_fixtures.dart';

void main() {
  final bucket = ReadingMissing<RatingSummary>(
    StoreFailure.notConfigured,
    'Add your reports bucket in Settings → Stores to see the rating.',
    fixtureCheckedAt,
  );

  test('a failure every app of a store shares is said once', () {
    final snapshots = [
      for (final id in ['a', 'b'])
        storeSnapshot(
          storeApp(StoreKind.googlePlay, 'com.example.$id'),
          rating: bucket,
        ),
    ];

    final shared = storeWideMissing(snapshots);

    expect(shared.single.store, StoreKind.googlePlay);
    expect(shared.single.areas, [StoreArea.rating]);
    expect(shared.single.expected, isTrue);
  });

  test('one app failing alone keeps its own signal', () {
    final failing = storeSnapshot(
      storeApp(StoreKind.appStore, 'com.example.a'),
      rating: ReadingMissing(
        StoreFailure.network,
        'The App Store could not be reached.',
        fixtureCheckedAt,
      ),
    );
    final fine = storeSnapshot(storeApp(StoreKind.appStore, 'com.example.b'));

    expect(storeWideMissing([failing, fine]), isEmpty);
    // The fixture's fresh review is a signal of its own; the failure is the
    // one unread signal.
    final signal = storeSignals(failing).whereType<UnreadSignal>().single;
    expect(signal.area, StoreArea.rating);
  });

  test('a rejection is loudest; a review this week is news', () {
    final app = storeApp(StoreKind.googlePlay, 'com.example.a');
    final signals = storeSignals(
      storeSnapshot(
        app,
        releases: [
          storeRelease(ReleaseState.inReview, version: '1.1.0'),
          storeRelease(ReleaseState.rejected, version: '1.2.0'),
        ],
      ),
    );

    expect(signals.first, isA<ReleaseSignal>());
    expect(signals.first.tone, StoreTone.attention);
    // The fixture's one review is two days older than its reading.
    expect(signals.whereType<NewReviewsSignal>().single.count, 1);
  });
}
