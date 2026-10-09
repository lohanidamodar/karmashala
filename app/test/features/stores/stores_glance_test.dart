import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_glance.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala/src/features/stores/presentation/stores_glance.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';
import 'store_history_fixtures.dart';

class _Stores extends StoresController {
  _Stores(this._state);

  final StoresState _state;

  @override
  Future<StoresState> build() async => _state;

  @override
  Future<void> refreshIfStale() async {}
}

/// The dashboard's Stores glance: the apps needing attention, the newest
/// release change, the rating's month, and a tap that opens the tab. Fake
/// store data only.
void main() {
  final now = DateTime.utc(2026, 9, 30, 11);
  final apple = AppleKeySummary(
    keyId: 'KEYID',
    issuerId: 'issuer',
    importedAt: DateTime.utc(2026, 9, 29),
  );
  final big = storeApp(StoreKind.appStore, 'com.example.big', name: 'Big');
  final stuck = storeApp(
    StoreKind.appStore,
    'com.example.stuck',
    name: 'Stuck',
  );

  StoresState state() => StoresState(
    view: StoresView(
      apple: apple,
      stores: {
        StoreKind.appStore: ReadingValue([big, stuck], fixtureCheckedAt),
      },
      apps: [
        storeSnapshot(
          big,
          rating: ReadingValue(
            RatingSummary(
              average: 4.6,
              count: 5000,
              history: [
                for (var day = 20; day <= 30; day++)
                  RatingPoint(DateTime.utc(2026, 9, day), 4.5 + day / 1000),
              ],
            ),
            fixtureCheckedAt,
          ),
          releases: [
            storeRelease(
              ReleaseState.live,
              version: '1.34.6',
              track: 'App Store',
            ),
          ],
        ),
        storeSnapshot(
          stuck,
          releases: [
            storeRelease(
              ReleaseState.rejected,
              version: '0.9.0',
              track: 'App Store',
            ),
          ],
        ),
      ],
      changes: [
        StoreAppChanges(
          app: stuck,
          platform: 'iOS',
          at: now.subtract(const Duration(hours: 5)),
          changes: const [
            StoreChange(
              kind: StoreChangeKind.release,
              text: '0.9.0 In review → Rejected',
              attention: true,
            ),
          ],
        ),
        StoreAppChanges(
          app: big,
          platform: 'iOS',
          at: now.subtract(const Duration(hours: 2)),
          changes: const [
            StoreChange(kind: StoreChangeKind.reviews, text: '1 new review'),
            StoreChange(
              kind: StoreChangeKind.release,
              text: '1.34.6 Approved → Ready for sale',
            ),
          ],
        ),
      ],
    ),
  );

  test('the short release change keeps the version and where it went', () {
    expect(
      shortReleaseChange('1.34.6 Approved → Ready for sale'),
      '1.34.6 Ready for sale',
    );
    expect(
      shortReleaseChange('New 1.35.0: Waiting for review'),
      '1.35.0 Waiting for review',
    );
    expect(
      shortReleaseChange('2.0 Developer action needed → Rolling out 20%'),
      '2.0 Rolling out 20%',
    );
  });

  test('the glance counts what needs attention and finds the newest', () async {
    final container = ProviderContainer(
      overrides: [storesProvider.overrideWith(() => _Stores(state()))],
    );
    addTearDown(container.dispose);
    await container.read(storesProvider.future);
    final data = container.read(storesGlanceProvider)!;
    expect(data.attention, 1);
    expect(data.firstAttention, 'Stuck (iOS)');
    expect(data.newestRelease?.text, '1.34.6 Ready for sale');
    expect(data.newestRelease?.app, 'Big (iOS)');
    expect(data.ratingApp, 'Big (iOS)');
    expect(data.ratingTrend, hasLength(11));
    expect(data.rating, 4.6);
  });

  test('no store connected is no glance data', () async {
    final container = ProviderContainer(
      overrides: [
        storesProvider.overrideWith(() => _Stores(const StoresState())),
      ],
    );
    addTearDown(container.dispose);
    await container.read(storesProvider.future);
    expect(container.read(storesGlanceProvider), isNull);
  });

  for (final size in kStoreTestSizes) {
    for (final scale in kStoreTestTextScales) {
      testWidgets('draws at ${size.width.round()} px, text ${scale}x', (
        tester,
      ) async {
        setStoreTestSurface(tester, size, scale);
        var opened = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              clockProvider.overrideWithValue(FixedClock(now)),
              storesProvider.overrideWith(() => _Stores(state())),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  // A dashboard tile's width, whatever the window.
                  child: SizedBox(
                    width: size.width < 600 ? size.width - 32 : 320,
                    child: StoresGlance(onOpen: () => opened++),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('1 needs attention · Stuck (iOS)'), findsOneWidget);
        expect(find.text('1.34.6 Ready for sale · 2h'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('stores-glance-sparkline')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('stores-glance')));
        expect(opened, 1);
      });
    }
  }
}
