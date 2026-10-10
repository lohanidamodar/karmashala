import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_summary.dart';
import 'package:karmashala/src/features/stores/application/stores_controller.dart';
import 'package:karmashala/src/features/stores/application/stores_layout_prefs.dart';
import 'package:karmashala/src/features/stores/presentation/store_app_card.dart';
import 'package:karmashala/src/features/stores/presentation/store_app_detail.dart';
import 'package:karmashala/src/features/stores/presentation/store_changes_view.dart';
import 'package:karmashala/src/features/stores/presentation/store_summary_table.dart';
import 'package:karmashala/src/features/stores/presentation/stores_tab_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';
import 'store_history_fixtures.dart';

/// **One list of apps, as a table or as cards** (round 87): each app once,
/// in the same sections either way, filtered by the count chips, the switch
/// kept per device. Fake store data only.
class _Stores extends StoresController {
  _Stores(this._state);

  final StoresState _state;

  @override
  Future<StoresState> build() async => _state;

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> refresh() async {}
}

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

void main() {
  final now = DateTime.utc(2026, 9, 30, 9, 12);

  StoreAppSnapshot snap(
    StoreApp app,
    List<StoreRelease> releases, {
    List<StoreReview> reviews = const [],
    VitalsSummary? vitals,
  }) {
    final base = storeSnapshot(app, releases: releases);
    return StoreAppSnapshot(
      app: app,
      releases: base.releases,
      reviews: ReadingValue(reviews, fixtureCheckedAt),
      rating: base.rating,
      vitals: vitals == null
          ? base.vitals
          : ReadingValue(vitals, fixtureCheckedAt),
      downloads: base.downloads,
    );
  }

  final notesIos = storeApp(
    StoreKind.appStore,
    'com.example.notes',
    name: 'Notes',
  );
  final notesPlay = storeApp(
    StoreKind.googlePlay,
    'com.example.notes',
    name: 'Notes',
  );
  final budget = storeApp(
    StoreKind.googlePlay,
    'com.example.budget',
    name: 'Budget',
  );
  final maps = storeApp(StoreKind.appStore, 'com.example.maps', name: 'Maps');
  final tasks = storeApp(
    StoreKind.appStore,
    'com.example.tasks',
    name: 'Tasks',
  );
  final listings = [notesIos, notesPlay, budget, maps, tasks];

  /// Notes on both stores, rejected on one: needs attention. Budget in
  /// review, Maps changed unseen, Tasks calm with a review nobody answered.
  StoresState state() => StoresState(
    view: StoresView(
      apple: AppleKeySummary(
        keyId: 'KEYID',
        issuerId: 'issuer',
        importedAt: DateTime.utc(2026, 9, 29),
      ),
      play: PlayAccountSummary(
        clientEmail: 'reader@example.iam.gserviceaccount.com',
        importedAt: DateTime.utc(2026, 9, 29),
      ),
      stores: {
        StoreKind.appStore: ReadingValue([
          notesIos,
          maps,
          tasks,
        ], fixtureCheckedAt),
        StoreKind.googlePlay: ReadingValue([
          notesPlay,
          budget,
        ], fixtureCheckedAt),
      },
      apps: [
        snap(notesIos, [
          storeRelease(ReleaseState.live, version: '2.3.0', track: 'App Store'),
          storeRelease(
            ReleaseState.rejected,
            version: '2.4.0',
            track: 'App Store',
          ),
        ]),
        snap(
          notesPlay,
          [storeRelease(ReleaseState.live, version: '2.2.0')],
          vitals: VitalsSummary(
            from: DateTime.utc(2026, 9, 1),
            to: DateTime.utc(2026, 9, 28),
            crashRate: 0.0042,
            anrRate: 0.0012,
          ),
        ),
        snap(budget, [
          storeRelease(
            ReleaseState.inReview,
            version: '1.1.0',
            track: 'production',
          ),
        ]),
        snap(maps, [
          storeRelease(ReleaseState.live, version: '3.0.0', track: 'App Store'),
        ]),
        snap(
          tasks,
          [
            storeRelease(
              ReleaseState.live,
              version: '1.0.0',
              track: 'App Store',
            ),
          ],
          reviews: [
            StoreReview(
              id: 'q',
              rating: 4,
              body: 'How do I export?',
              createdAt: DateTime.utc(2026, 9, 29),
            ),
          ],
        ),
      ],
      changes: [
        StoreAppChanges(
          app: maps,
          platform: 'iOS',
          at: now,
          changes: const [
            StoreChange(
              kind: StoreChangeKind.reviews,
              text: '1 new review (5★)',
            ),
          ],
        ),
      ],
      refreshedAt: now.subtract(const Duration(minutes: 12)),
    ),
  );

  Future<MemoryStoresLayoutStore> pump(
    WidgetTester tester, {
    required Size size,
    StoresLayout? kept,
    double textScale = 1,
  }) async {
    setStoreTestSurface(tester, size, textScale);
    final prefs = MemoryStoresLayoutStore(kept);
    await tester.pumpWidget(
      ProviderScope(
        // A container of its own each time, so nothing carries over.
        key: UniqueKey(),
        overrides: [
          clockProvider.overrideWithValue(FixedClock(now)),
          storesProvider.overrideWith(() => _Stores(state())),
          storesLayoutStoreProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(home: StoresTabView()),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  /// The section headings, top to bottom, in whichever view is drawn.
  List<String> headings(WidgetTester tester) {
    final found = <(double, String)>[];
    for (final section in StoreSection.values) {
      final finder = find.textContaining(
        section.title.toUpperCase(),
        findRichText: true,
      );
      if (finder.evaluate().isEmpty) continue;
      found.add((tester.getTopLeft(finder.first).dy, section.title));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, title) in found) title];
  }

  const sectionOrder = [
    'Needs attention',
    'In progress',
    'Changed since you last looked',
    'Everything else',
  ];

  test('an app is in the first section that holds of it', () {
    final groups = state().groups;
    expect(
      {
        for (final (section, members) in storeSections(groups))
          section: [for (final group in members) group.name],
      },
      {
        StoreSection.attention: ['Notes'],
        StoreSection.inProgress: ['Budget'],
        StoreSection.changed: ['Maps'],
        StoreSection.rest: ['Tasks'],
      },
    );
  });

  testWidgets('a desktop opens on the table, a phone on the cards', (
    tester,
  ) async {
    await pump(tester, size: _desktop);
    expect(find.byType(StoreSummaryTable), findsOneWidget);
    expect(find.byType(StoreGroupCard), findsNothing);

    await pump(tester, size: _phone);
    expect(find.byType(StoreSummaryTable), findsNothing);
    expect(find.byType(StoreGroupCard), findsNWidgets(4));
  });

  testWidgets('the switch is kept, and a kept choice wins over the width', (
    tester,
  ) async {
    final prefs = await pump(tester, size: _desktop);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('stores-layout')),
        matching: find.text('Cards'),
      ),
    );
    await tester.pumpAndSettle();
    expect(prefs.saved, [StoresLayout.cards]);
    expect(find.byType(StoreGroupCard), findsNWidgets(4));

    await pump(tester, size: _desktop, kept: StoresLayout.cards);
    expect(find.byType(StoreGroupCard), findsNWidgets(4));
    await pump(tester, size: _phone, kept: StoresLayout.table);
    expect(find.byType(StoreSummaryTable), findsOneWidget);
  });

  for (final size in [_phone, _desktop]) {
    final width = size.width.round();

    testWidgets('each app is listed once, in the same sections, either way '
        '($width)', (tester) async {
      await pump(tester, size: size, kept: StoresLayout.table);
      // A row per store listing, each once; nothing above the list repeats
      // them.
      for (final app in listings) {
        expect(
          find.byKey(ValueKey('store-summary-row:${app.key}')),
          findsOneWidget,
        );
      }
      expect(find.byType(StoreGroupCard), findsNothing);
      expect(headings(tester), sectionOrder);

      await pump(tester, size: size, kept: StoresLayout.cards);
      expect(find.byType(StoreGroupCard), findsNWidgets(4));
      for (final name in ['Notes', 'Budget', 'Maps', 'Tasks']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.byType(StoreSummaryTable), findsNothing);
      expect(headings(tester), sectionOrder);
    });

    testWidgets('the count chips filter both views, a zero left out '
        '($width)', (tester) async {
      for (final layout in StoresLayout.values) {
        await pump(tester, size: size, kept: layout);
        expect(find.text('Needs attention 1'), findsOneWidget);
        expect(find.text('In progress 1'), findsOneWidget);
        expect(find.text('New reviews 1'), findsOneWidget);
        expect(find.text('All 4'), findsOneWidget);

        await tester.tap(find.text('In progress 1'));
        await tester.pumpAndSettle();
        expect(find.text('Budget'), findsOneWidget);
        expect(find.text('Notes'), findsNothing);
        expect(find.text('Tasks'), findsNothing);
        // One section: no heading to tell it from another.
        expect(headings(tester), isEmpty);

        await tester.tap(find.text('All 4'));
        await tester.pumpAndSettle();
        expect(headings(tester), sectionOrder);
      }

      // Nothing new to read anywhere: that chip is not drawn.
      final quiet = state().view;
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            clockProvider.overrideWithValue(FixedClock(now)),
            storesProvider.overrideWith(
              () => _Stores(
                StoresState(
                  view: StoresView(
                    apple: quiet.apple,
                    play: quiet.play,
                    stores: quiet.stores,
                    apps: [
                      for (final app in quiet.apps)
                        if (app.app != tasks) app,
                    ],
                    refreshedAt: quiet.refreshedAt,
                  ),
                ),
              ),
            ),
            storesLayoutStoreProvider.overrideWithValue(
              MemoryStoresLayoutStore(),
            ),
          ],
          child: const MaterialApp(home: StoresTabView()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('stores-filter:newReviews')),
        findsNothing,
      );
      expect(find.text('All 4'), findsOneWidget);
    });

    testWidgets('a card carries the facts its table row has ($width)', (
      tester,
    ) async {
      await pump(tester, size: size, kept: StoresLayout.cards);
      // Every listing read: a line of the table's other facts under it.
      for (final app in listings) {
        expect(
          find.byKey(ValueKey('store-listing-facts:${app.key}')),
          findsOneWidget,
        );
      }
      expect(find.text('Crashes 0.42% · ANRs 0.12%'), findsOneWidget);
      expect(find.text('1 new · 1 unanswered'), findsOneWidget);
      expect(find.text('Crashes · ANRs not reported'), findsWidgets);
      // The changed marker, as the table's bell says it.
      expect(find.byType(StoreChangedMarker), findsOneWidget);

      await pump(tester, size: size, kept: StoresLayout.table);
      expect(find.text('1 new · 1 unanswered'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('store-summary-changed')),
        findsOneWidget,
      );
    });
  }

  testWidgets('a row opens its detail beside the table, which still works', (
    tester,
  ) async {
    await pump(tester, size: _desktop);
    await tester.tap(find.byKey(ValueKey('store-summary-row:${budget.key}')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(StoreGroupDetail), findsOneWidget);
    expect(find.byType(StoreSummaryTable), findsOneWidget);

    // Another row from the narrowed list opens that app instead.
    await tester.tap(find.byKey(ValueKey('store-summary-row:${maps.key}')));
    await tester.pumpAndSettle();
    expect(find.byType(StoreGroupDetail), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StoreGroupDetail),
        matching: find.text('Maps'),
      ),
      findsWidgets,
    );
  });

  for (final size in const [
    Size(360, 800),
    Size(412, 900),
    Size(768, 1024),
    Size(1440, 900),
  ]) {
    for (final scale in const [1.0, 1.6]) {
      for (final layout in StoresLayout.values) {
        testWidgets(
          '${layout.label} fits at ${size.width.round()} px, text ${scale}x',
          (tester) async {
            await pump(tester, size: size, kept: layout, textScale: scale);
            expect(tester.takeException(), isNull);
            expect(
              find.byType(StoreSummaryTable),
              layout == StoresLayout.table ? findsOneWidget : findsNothing,
            );
          },
        );
      }
    }
  }
}
