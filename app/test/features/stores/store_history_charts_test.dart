import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_groups.dart';
import 'package:karmashala/src/features/stores/application/store_history.dart';
import 'package:karmashala/src/features/stores/presentation/store_history_charts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:store_console/store_console.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';
import 'store_history_fixtures.dart';

/// The detail's charts over time: what each draws from the kept days, gaps
/// for days nobody read, release markers, and the range picker. Fake store
/// data only.
void main() {
  final now = DateTime.utc(2026, 10, 9, 12);
  final days = storeDays(now);

  group('chart data', () {
    test('a day without a value is left out, never a zero', () {
      final crash = storeDaySeries(
        days,
        (day) => day.crashRate,
        from: storeRangeStart(StoreChartRange.month, now),
      );
      expect(crash.every((point) => point.value > 0), isTrue);
      expect(crash.length, lessThan(days.length));
      // Every third day was never read: there is no point for it at all.
      final read = {for (final day in days) day.day};
      expect(read, isNot(contains(DateTime.utc(2026, 10, 8))));
      expect(
        crash.map((point) => point.day),
        isNot(contains(DateTime.utc(2026, 10, 8))),
      );
    });

    test('the range clips the days shown', () {
      final from = storeRangeStart(StoreChartRange.month, now);
      expect(from, DateTime.utc(2026, 9, 10));
      final kept = storeDaySeries(
        [StoreDay(day: DateTime.utc(2026, 9, 1), rating: 4), ...days],
        (day) => day.rating,
        from: from,
      );
      expect(kept.first.day.isBefore(from), isFalse);
    });

    test('reviews a week: a week nobody counted is unknown, not none', () {
      final weeks = storeWeeklyReviews(
        [
          StoreDay(day: DateTime.utc(2026, 9, 28), reviews: 2),
          StoreDay(day: DateTime.utc(2026, 9, 30), reviews: 0),
          StoreDay(day: DateTime.utc(2026, 10, 7), reviews: 3),
        ],
        from: DateTime.utc(2026, 9, 21),
        to: now,
      );
      expect(weeks.map((week) => week.week), [
        DateTime.utc(2026, 9, 21),
        DateTime.utc(2026, 9, 28),
        DateTime.utc(2026, 10, 5),
      ]);
      expect(weeks.map((week) => week.count), [null, 2, 3]);
    });

    test('release dates mark what went out, not what was first read', () {
      final dates = storeReleaseDates(StoreKind.appStore, appleSteps());
      expect(dates, [(at: DateTime.utc(2026, 9, 22, 9), version: '2.3.0')]);
      final play = storeReleaseDates(StoreKind.googlePlay, playSteps());
      // The rollout's first step is when it went out.
      expect(play, [(at: DateTime.utc(2026, 10, 2, 10), version: '2.0.0')]);
    });
  });

  group('StoreHistoryCharts', () {
    final playApp = storeApp(StoreKind.googlePlay, 'com.example.notes');
    final group = StoreAppGroup(
      bundleId: 'com.example.notes',
      entries: [StoreEntry(playApp, storeSnapshot(playApp))],
    );
    final view = StoreHistoryView(
      keptDays: 365,
      apps: [StoreAppHistory(app: playApp, days: days, steps: playSteps())],
    );

    Future<void> pump(
      WidgetTester tester,
      StoreHistoryView view, {
      bool narrow = false,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(FixedClock(now)),
            storeHistoryProvider.overrideWith((ref, keys) async => view),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: StoreHistoryCharts(group: group, narrow: narrow),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final size in kStoreTestSizes) {
      for (final scale in kStoreTestTextScales) {
        testWidgets('draws at ${size.width.round()} px, text ${scale}x', (
          tester,
        ) async {
          setStoreTestSurface(tester, size, scale);
          await pump(tester, view, narrow: size.width < 600);
          expect(tester.takeException(), isNull);
          for (final key in ['rating', 'reviews', 'crash', 'anr', 'installs']) {
            expect(find.byKey(ValueKey('store-history-$key')), findsOneWidget);
          }
          // Play reports no ANR rate in this fixture: said, not drawn as 0.
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('store-history-anr')),
              matching: find.text(kNotRecorded),
            ),
            findsOneWidget,
          );
          expect(find.byType(TimeSeriesChart), findsNWidgets(3));
          expect(find.byType(BarChart), findsOneWidget);
        });
      }
    }

    testWidgets('the range picker widens what the charts show', (tester) async {
      setStoreTestSurface(tester, const Size(1440, 900), 1.0);
      await pump(tester, view);
      DateTime start() => tester
          .widget<TimeSeriesChart>(find.byType(TimeSeriesChart).first)
          .start;
      expect(start(), DateTime.utc(2026, 9, 10));
      expect(
        tester
            .widget<TimeSeriesChart>(find.byType(TimeSeriesChart).first)
            .markers
            .map((marker) => marker.label),
        ['2.0.0'],
      );
      await tester.tap(find.text('90 days'));
      await tester.pumpAndSettle();
      expect(start(), DateTime.utc(2026, 7, 12));
      await tester.tap(find.text('365 days'));
      await tester.pumpAndSettle();
      expect(start(), DateTime.utc(2025, 10, 10));
      // Unknown days stay gaps: the chart is told to break, not to join.
      expect(
        tester
            .widget<TimeSeriesChart>(find.byType(TimeSeriesChart).first)
            .breakAfter,
        kHistoryChartBreak,
      );
    });

    testWidgets('says so when nothing is kept yet', (tester) async {
      setStoreTestSurface(tester, const Size(360, 800), 1.0);
      await pump(tester, const StoreHistoryView(), narrow: true);
      expect(find.byKey(const ValueKey('store-history-empty')), findsOne);
    });
  });
}
