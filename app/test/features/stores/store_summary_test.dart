import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_groups.dart';
import 'package:karmashala/src/features/stores/application/store_summary.dart';
import 'package:karmashala/src/features/stores/presentation/store_summary_table.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';
import 'store_history_fixtures.dart';

/// The summary across every app: its rows, what sorts first, and how it is
/// drawn on a phone and a desktop. Fake store data only.
void main() {
  final now = DateTime.utc(2026, 9, 30, 9);

  StoreAppSnapshot withVitals(StoreAppSnapshot snapshot, VitalsSummary v) =>
      StoreAppSnapshot(
        app: snapshot.app,
        releases: snapshot.releases,
        reviews: snapshot.reviews,
        rating: snapshot.rating,
        vitals: ReadingValue(v, fixtureCheckedAt),
        downloads: snapshot.downloads,
      );

  StoreAppSnapshot withReviews(
    StoreAppSnapshot snapshot,
    List<StoreReview> reviews,
  ) => StoreAppSnapshot(
    app: snapshot.app,
    releases: snapshot.releases,
    reviews: ReadingValue(reviews, fixtureCheckedAt),
    rating: snapshot.rating,
    vitals: snapshot.vitals,
    downloads: snapshot.downloads,
  );

  final calm = storeApp(StoreKind.appStore, 'com.example.calm', name: 'Calm');
  final rejected = storeApp(StoreKind.appStore, 'com.example.zed', name: 'Zed');
  final moving = storeApp(
    StoreKind.googlePlay,
    'com.example.moving',
    name: 'Moving',
  );
  final changed = storeApp(
    StoreKind.appStore,
    'com.example.changed',
    name: 'Changed',
  );
  final unanswered = storeApp(
    StoreKind.googlePlay,
    'com.example.asked',
    name: 'Asked',
  );

  List<StoreAppGroup> groups() => groupStoreApps(
    [calm, rejected, moving, changed, unanswered],
    {
      calm: storeSnapshot(
        calm,
        releases: [
          storeRelease(ReleaseState.live, version: '1.0.0', track: 'App Store'),
        ],
      ),
      rejected: storeSnapshot(
        rejected,
        releases: [
          storeRelease(ReleaseState.live, version: '3.1.0', track: 'App Store'),
          storeRelease(
            ReleaseState.rejected,
            version: '3.2.0',
            track: 'App Store',
          ),
        ],
      ),
      moving: withVitals(
        storeSnapshot(
          moving,
          releases: [
            storeRelease(
              ReleaseState.rollingOut,
              version: '5.0.0',
              rolloutFraction: 0.2,
            ),
          ],
        ),
        VitalsSummary(
          from: DateTime.utc(2026, 9, 1),
          to: DateTime.utc(2026, 9, 28),
          crashRate: 0.0042,
          anrRate: 0.0012,
        ),
      ),
      changed: storeSnapshot(
        changed,
        releases: [
          storeRelease(ReleaseState.live, version: '1.0.0', track: 'App Store'),
        ],
      ),
      unanswered: withReviews(
        storeSnapshot(
          unanswered,
          releases: [storeRelease(ReleaseState.live, version: '4.0.0')],
        ),
        [
          StoreReview(
            id: 'q',
            rating: 4,
            body: 'How do I export?',
            createdAt: DateTime.utc(2026, 9, 29),
          ),
        ],
      ),
    },
    changes: {
      changed.key: StoreAppChanges(
        app: changed,
        platform: 'iOS',
        at: now,
        changes: const [
          StoreChange(kind: StoreChangeKind.reviews, text: '1 new review (5★)'),
        ],
      ),
    },
  );

  test('rows sort what needs attention first', () {
    final rows = storeSummaryRows(groups());
    expect(rows.map((row) => row.app.name), [
      'Zed', // rejected
      'Moving', // rolling out
      'Changed', // changed, unseen
      'Asked', // an unanswered review
      'Calm',
    ]);
    expect(rows.first.needsAttention, isTrue);
    expect(rows[1].inFlight, isTrue);
    expect(rows[2].changedUnseen, isTrue);
    expect(rows[3].unanswered, 1);
    expect(rows.last.rank, 4);
  });

  test('a row says its platform, live version, stability and reviews', () {
    final rows = {
      for (final row in storeSummaryRows(groups())) row.app.name: row,
    };
    expect(rows['Moving']!.platform, 'Android');
    expect(rows['Calm']!.platform, 'iOS');
    expect(rows['Zed']!.live?.version, '3.1.0');
    expect(rows['Zed']!.pending?.version, '3.2.0');
    expect(rows['Moving']!.vitals?.crashRate, 0.0042);
    // The App Store reports no crash rate: unknown, not zero.
    expect(rows['Calm']!.vitals, isNull);
    // The fixture's review is answered.
    expect(rows['Calm']!.newReviewCount, 1);
    expect(rows['Calm']!.unanswered, 0);
  });

  test('the rating trend covers 30 days, days unread left out', () {
    final app = storeApp(StoreKind.appStore, 'com.example.r');
    final group = groupStoreApps(
      [app],
      {
        app: storeSnapshot(
          app,
          rating: ReadingValue(
            RatingSummary(
              average: 4.4,
              history: [
                RatingPoint(DateTime.utc(2026, 8, 31), 3.5),
                for (final day in [2, 4, 9, 30])
                  RatingPoint(DateTime.utc(2026, 9, day), 4 + day / 100),
              ],
            ),
            fixtureCheckedAt,
          ),
        ),
      },
    );
    final trend = storeSummaryRows(group).single.ratingTrend;
    // 31 Aug falls outside the 30 days ending 30 Sep; the 5th is a gap.
    expect(trend, [4.02, 4.04, 4.09, 4.3]);
  });

  for (final size in kStoreTestSizes) {
    for (final scale in kStoreTestTextScales) {
      testWidgets(
        'draws at ${size.width.round()} px, text ${scale}x, and opens a row',
        (tester) async {
          setStoreTestSurface(tester, size, scale);
          final opened = <String>[];
          final rows = storeSummaryRows(groups());
          await tester.pumpWidget(
            ProviderScope(
              overrides: [clockProvider.overrideWithValue(FixedClock(now))],
              child: MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: StoreSummaryTable(rows: rows, onOpen: opened.add),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Zed'), findsOneWidget);
          expect(find.text('Crashes 0.42% · ANRs 0.12%'), findsOneWidget);
          expect(find.text(kNotReported), findsWidgets);
          expect(
            find.byKey(const ValueKey('store-summary-changed')),
            findsOneWidget,
          );
          // A table header only where it is wide.
          expect(
            find.text('Crashes · ANRs'),
            size.width >= 1000 ? findsOneWidget : findsNothing,
          );
          await tester.tap(find.text('Moving'));
          expect(opened, [rows[1].group.key]);
        },
      );
    }
  }
}
