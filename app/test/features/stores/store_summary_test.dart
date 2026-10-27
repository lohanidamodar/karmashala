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

  test('a rating trend is drawn on its own range, half a star at least', () {
    final narrow = ratingTrendScale(const [4.4, 4.5]);
    expect(narrow.min, closeTo(4.15, 1e-9));
    expect(narrow.max, closeTo(4.75, 1e-9));
    final wide = ratingTrendScale(const [3.0, 4.6]);
    expect(wide.min, closeTo(2.95, 1e-9));
    expect(wide.max, closeTo(4.65, 1e-9));
    expect(ratingTrendScale(const []), (min: 1.0, max: 5.0));
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

  test('the sections run attention, moving, changed, the rest', () {
    expect(
      [
        for (final (section, members) in storeSections(groups()))
          '${section.name}: ${members.map((group) => group.name).join(', ')}',
      ],
      [
        'attention: Zed',
        'inProgress: Moving',
        'changed: Changed',
        // An unanswered review is new reviews' filter, not a section.
        'rest: Asked, Calm',
      ],
    );
  });

  testWidgets('a heading row starts each section, and the open app is marked', (
    tester,
  ) async {
    setStoreTestSurface(tester, const Size(1440, 900), 1);
    final sections = [
      for (final (section, members) in storeSections(groups()))
        (
          title: section.title,
          apps: members.length,
          rows: storeSummaryApps(members),
        ),
    ];
    final open = sections[1].rows.single.key;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clockProvider.overrideWithValue(FixedClock(now))],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StoreSummaryTable(
                sections: sections,
                selected: open,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final titles = [
      'NEEDS ATTENTION · 1',
      'IN PROGRESS · 1',
      'CHANGED SINCE YOU LAST LOOKED · 1',
      'EVERYTHING ELSE · 2',
    ];
    for (final title in titles) {
      expect(find.text(title), findsOneWidget);
    }
    // Each heading sits above its section's first row.
    expect(
      tester.getTopLeft(find.text(titles[1])).dy,
      lessThan(tester.getTopLeft(find.text('Moving')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Zed')).dy,
      lessThan(tester.getTopLeft(find.text(titles[1])).dy),
    );
    expect(
      tester.getSemantics(find.text('Moving')),
      isSemantics(isSelected: true, isButton: true, hasSelectedState: true),
    );
  });

  for (final size in kStoreTestSizes) {
    for (final scale in kStoreTestTextScales) {
      testWidgets(
        'draws at ${size.width.round()} px, text ${scale}x, and opens a row',
        (tester) async {
          setStoreTestSurface(tester, size, scale);
          final opened = <String>[];
          final apps = storeSummaryApps(groups());
          await tester.pumpWidget(
            ProviderScope(
              overrides: [clockProvider.overrideWithValue(FixedClock(now))],
              child: MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: StoreSummaryTable(
                      sections: [(title: null, apps: apps.length, rows: apps)],
                      onOpen: opened.add,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Zed'), findsOneWidget);
          expect(find.text('Crashes 0.42% · ANRs 0.12%'), findsOneWidget);
          // On a phone the stability says what is not reported.
          expect(find.textContaining(kNotReported), findsWidgets);
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
          expect(opened, [apps.singleWhere((app) => app.name == 'Moving').key]);
        },
      );
    }
  }

  group('one row per app', () {
    InstallTotal counted(int count, {String? since, int? devices}) =>
        InstallTotal(
          count: count,
          measure: 'user installs',
          source: InstallTotalSource.reports,
          since: since,
          through: DateTime.utc(2026, 9, 28),
          activeDevices: devices,
          activeDevicesDay: devices == null ? null : DateTime.utc(2026, 9, 28),
        );

    StoreAppSnapshot installed(StoreApp app, InstallTotal? total) =>
        storeSnapshot(
          app,
          releases: [storeRelease(ReleaseState.live)],
        ).withAllTimeInstalls(
          total == null
              ? ReadingMissing(
                  StoreFailure.permission,
                  'This key may not read sales reports.',
                  fixtureCheckedAt,
                )
              : ReadingValue(total, fixtureCheckedAt),
        );

    final tideIos = storeApp(
      StoreKind.appStore,
      'com.example.tide',
      name: 'Tide',
    );
    final tidePlay = storeApp(
      StoreKind.googlePlay,
      'com.example.tide',
      name: 'Tide',
    );
    final parkIos = storeApp(
      StoreKind.appStore,
      'com.example.park.ios',
      name: 'Parkline',
    );
    final parkPlay = storeApp(
      StoreKind.googlePlay,
      'com.example.parkline',
      name: 'Parkline',
    );
    final ledger = storeApp(
      StoreKind.googlePlay,
      'com.example.ledger',
      name: 'Ledger',
    );

    List<StoreAppGroup> both({
      InstallTotal? tideApple,
      InstallTotal? tideGoogle,
      InstallTotal? park,
      InstallTotal? ledgerTotal,
    }) => groupStoreApps(
      [tideIos, tidePlay, parkIos, parkPlay, ledger],
      {
        tideIos: installed(tideIos, tideApple),
        tidePlay: installed(tidePlay, tideGoogle),
        parkIos: installed(parkIos, null),
        parkPlay: installed(parkPlay, park),
        ledger: installed(ledger, ledgerTotal),
      },
      links: [StoreAppLink(appStoreId: parkIos.id, packageName: parkPlay.id)],
    );

    StoreSummaryApp named(List<StoreAppGroup> groups, String name) =>
        storeSummaryApps(groups).singleWhere((app) => app.name == name);

    test('a row per group, combined pairs and one-store apps alike', () {
      final apps = storeSummaryApps(both());
      expect(apps.map((app) => app.name), ['Ledger', 'Parkline', 'Tide']);
      final tide = apps.last;
      expect(tide.onBoth, isTrue);
      expect(tide.group.combinedManually, isFalse);
      // App Store first, then Google Play.
      expect(tide.stores.map((row) => row.app.store), [
        StoreKind.appStore,
        StoreKind.googlePlay,
      ]);
      final park = apps[1];
      expect(park.onBoth, isTrue);
      expect(park.group.combinedManually, isTrue);
      expect(park.stores.map((row) => row.app.bundleId), [
        'com.example.park.ios',
        'com.example.parkline',
      ]);
      expect(apps.first.onBoth, isFalse);
      expect(apps.first.stores.single.app.store, StoreKind.googlePlay);
    });

    test('exact counts add up, each labelled with where it starts', () {
      final tide = named(
        both(
          tideApple: counted(600, since: '2025-01'),
          tideGoogle: counted(1800, since: '2019-03', devices: 480),
        ),
        'Tide',
      );
      final installs = tide.installs;
      expect(installs.count, 2400);
      expect(installs.missing, isEmpty);
      expect(installs.lifetime, isFalse);
      expect(
        summaryInstallsPeriod(installs, tide),
        'App Store since Jan 2025 · Play since Mar 2019',
      );
      expect(tide.activeDevices, 480);
      // 14 fixture days on each store: 10 + 20 + … + 140.
      expect(tide.recentInstalls, 2100);
    });

    test('a store not read is named, the sum never called all time', () {
      final park = named(
        both(park: counted(990, since: '2025-04')),
        'Parkline',
      );
      expect(park.installs.count, 990);
      expect(park.installs.missing, [StoreKind.appStore]);
      expect(
        summaryInstallsPeriod(park.installs, park),
        'Play only, since Apr 2025',
      );
    });

    test('a partial App Store sum says the period it covers', () {
      final tide = named(
        both(tideApple: counted(61, since: '2025-03')),
        'Tide',
      );
      final period = summaryInstallsPeriod(tide.installs, tide);
      expect(period, 'App Store only, since Mar 2025');
      expect(period, isNot(contains('all time')));
    });

    test('all time only where every store gave its own lifetime count', () {
      final ledgerApp = named(both(ledgerTotal: counted(120)), 'Ledger');
      expect(ledgerApp.installs.lifetime, isTrue);
      expect(summaryInstallsPeriod(ledgerApp.installs, ledgerApp), 'all time');
      final mixed = named(
        both(
          tideApple: counted(5, since: '2026-01'),
          tideGoogle: counted(9),
        ),
        'Tide',
      );
      expect(
        summaryInstallsPeriod(mixed.installs, mixed),
        'App Store since Jan 2026 · Play all time',
      );
    });

    test('a listing band is never added to an exact count', () {
      final band = InstallTotal.fromBand('10K+')!;
      final alone = named(both(ledgerTotal: band), 'Ledger');
      expect(alone.installs.count, isNull);
      expect(summaryInstallsFigure(alone.installs), '10K+');
      expect(summaryInstallsPeriod(alone.installs, alone), 'Play listing band');
      final beside = named(
        both(
          tideApple: counted(70, since: '2026-02'),
          tideGoogle: band,
        ),
        'Tide',
      );
      expect(beside.installs.count, 70);
      expect(beside.installs.missing, [StoreKind.googlePlay]);
    });

    test('no count anywhere is not reported, not zero', () {
      final ledgerApp = named(both(), 'Ledger');
      expect(summaryInstallsFigure(ledgerApp.installs), isNull);
      expect(ledgerApp.activeDevices, isNull);
    });

    test('recent installs keep to the 30 days up to the newest', () {
      final app = storeApp(StoreKind.googlePlay, 'com.example.r');
      final group = groupStoreApps(
        [app],
        {
          app: storeSnapshot(
            app,
            downloads: ReadingValue(
              DownloadSeries(
                unit: 'Installs',
                days: [
                  DailyCount(DateTime.utc(2026, 8, 1), 1000),
                  DailyCount(DateTime.utc(2026, 9, 1), 4),
                  DailyCount(DateTime.utc(2026, 9, 30), 6),
                ],
              ),
              fixtureCheckedAt,
            ),
          ),
        },
      );
      final row = storeSummaryApps(group).single;
      expect(row.stores.single.recentInstalls, (count: 10, days: 2));
      expect(row.recentInstalls, 10);
    });

    for (final size in kStoreTestSizes) {
      for (final scale in kStoreTestTextScales) {
        testWidgets(
          'combined rows draw at ${size.width.round()} px, text ${scale}x',
          (tester) async {
            setStoreTestSurface(tester, size, scale);
            final apps = storeSummaryApps(
              both(
                tideApple: counted(61904, since: '2025-01'),
                tideGoogle: counted(182410, since: '2019-03', devices: 48200),
                park: counted(9870, since: '2025-04', devices: 3400),
                ledgerTotal: InstallTotal.fromBand('1K+'),
              ),
            );
            await tester.pumpWidget(
              ProviderScope(
                overrides: [clockProvider.overrideWithValue(FixedClock(now))],
                child: MaterialApp(
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: StoreSummaryTable(
                        sections: [
                          (title: null, apps: apps.length, rows: apps),
                        ],
                        onOpen: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            // One row per app, whatever stores it is on.
            for (final app in apps) {
              expect(
                find.byKey(ValueKey('store-summary-row:${app.key}')),
                findsOneWidget,
              );
            }
            expect(find.text('Tide'), findsOneWidget);
            expect(
              find.byKey(const ValueKey('store-summary-combined')),
              findsOneWidget,
            );
            final tide = apps.singleWhere((app) => app.name == 'Tide');
            expect(
              find.byKey(ValueKey('store-summary-devices:${tide.key}')),
              findsOneWidget,
            );
            expect(
              find.textContaining('Play only, since Apr 2025'),
              findsOneWidget,
            );
            expect(
              find.text('Active devices'),
              size.width >= 1000 ? findsOneWidget : findsNothing,
            );
          },
        );
      }
    }
  });
}
