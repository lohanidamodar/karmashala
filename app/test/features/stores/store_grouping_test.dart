import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/stores/application/store_credentials.dart';
import 'package:karmashala/src/features/stores/application/stores_dashboard.dart';
import 'package:store_console/store_console.dart';

import 'store_fixtures.dart';

void main() {
  test('an app on both stores is one group, App Store first', () {
    final play = storeApp(StoreKind.googlePlay, 'com.example.notes');
    final apple = storeApp(StoreKind.appStore, 'com.example.notes');
    final other = storeApp(StoreKind.googlePlay, 'com.example.other');

    final groups = groupStoreApps([play, apple, other], const {});

    expect(groups.map((group) => group.bundleId), [
      'com.example.notes',
      'com.example.other',
    ]);
    expect(groups.first.entries.map((entry) => entry.app.store), [
      StoreKind.appStore,
      StoreKind.googlePlay,
    ]);
    // Not read yet is not a release state.
    expect(groups.first.entries.first.snapshot, isNull);
    expect(groups.first.needsAttention, isFalse);
  });

  test('attention first, then in flight, then by name', () {
    final settled = storeApp(StoreKind.appStore, 'a.settled', name: 'Alpha');
    final rolling = storeApp(StoreKind.googlePlay, 'b.rolling', name: 'Mango');
    final rejected = storeApp(StoreKind.appStore, 'c.rejected', name: 'Zebra');
    final quiet = storeApp(StoreKind.googlePlay, 'd.quiet', name: 'beta');

    final groups = groupStoreApps(
      [settled, rolling, rejected, quiet],
      {
        settled: storeSnapshot(
          settled,
          releases: [storeRelease(ReleaseState.live)],
        ),
        rolling: storeSnapshot(
          rolling,
          releases: [
            storeRelease(ReleaseState.rollingOut, rolloutFraction: 0.2),
          ],
        ),
        rejected: storeSnapshot(
          rejected,
          releases: [
            storeRelease(ReleaseState.live),
            storeRelease(ReleaseState.inReview, version: '1.1.0'),
            storeRelease(ReleaseState.rejected, version: '1.2.0'),
          ],
        ),
      },
    );

    expect(groups.map((group) => group.name), [
      'Zebra',
      'Mango',
      'Alpha',
      'beta',
    ]);
    // The release somebody must act on outranks the one merely waiting.
    expect(groups.first.entries.single.pending?.state, ReleaseState.rejected);
  });

  test('the same app listed twice is one entry', () {
    final app = storeApp(StoreKind.googlePlay, 'com.example.notes');
    final groups = groupStoreApps([app, app], const {});
    expect(groups.single.entries, hasLength(1));
  });

  test('package names are split on commas and new lines', () {
    expect(parsePackageNames(' com.a.one, com.a.two\ncom.a.one\n\n'), [
      'com.a.one',
      'com.a.two',
    ]);
  });
}
