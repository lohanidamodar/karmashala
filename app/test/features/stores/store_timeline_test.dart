import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/stores/application/store_groups.dart';
import 'package:karmashala/src/features/stores/application/store_history.dart';
import 'package:karmashala/src/features/stores/application/store_timeline.dart';
import 'package:karmashala/src/features/stores/presentation/store_release_timeline.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

import '../../support/fakes.dart';
import 'store_fixtures.dart';
import 'store_history_fixtures.dart';

/// Each release's path from the steps the server kept: a rejection, Play's
/// rollout steps, how long review usually takes, drawn across a wide detail
/// and down a phone. Fake store data only.
void main() {
  final now = DateTime.utc(2026, 10, 9, 12);

  group('releaseTimelines', () {
    test(
      'a rejected release ends at the rejection, with what the store said',
      () {
        final timelines = releaseTimelines(
          StoreKind.appStore,
          appleSteps(),
          now: now,
        );
        expect(timelines.map((t) => t.name), ['2.4.0', '2.3.0', '2.2.0']);
        final rejected = timelines.first;
        expect(rejected.rejected, isTrue);
        expect(rejected.rejectionReason, 'Metadata rejected');
        expect(rejected.steps.map((s) => s.words), [
          'Waiting for review',
          'In review',
          'Metadata rejected',
        ]);
        expect(rejected.steps[0].spent, const Duration(hours: 25));
        expect(rejected.steps[1].spent, const Duration(hours: 3));
        // A rejection ends the path: no time is counted on it.
        expect(rejected.steps.last.spent, isNull);
        expect(rejected.steps.last.current, isTrue);
        expect(rejected.reviewTime, const Duration(hours: 28));
      },
    );

    test('Play\'s rollout steps each take their time until it is live', () {
      final timeline = releaseTimelines(
        StoreKind.googlePlay,
        playSteps(),
        now: now,
      ).single;
      expect(timeline.steps.map((s) => s.words), [
        'In review',
        'Rolling out 10%',
        'Rolling out 50%',
        'Live',
      ]);
      expect(timeline.steps.map((s) => s.rollout), [null, 0.1, 0.5, null]);
      expect(timeline.steps[1].spent, const Duration(days: 2));
      expect(timeline.reviewTime, const Duration(hours: 26));
      expect(timeline.rejected, isFalse);
    });

    test('a release first read already there counts its time as a floor', () {
      final first = releaseTimelines(
        StoreKind.appStore,
        appleSteps(),
        now: now,
      ).last;
      expect(first.steps.single.atLeast, isTrue);
      // Live ends the path.
      expect(first.steps.single.spent, isNull);
      expect(first.reviewTime, isNull);
      expect(
        stepSpent(
          ReleaseTimelineStep(
            words: 'In review',
            state: ReleaseState.inReview,
            at: now,
            spent: Duration(hours: 5),
            atLeast: true,
            current: true,
          ),
        ),
        '≥ 5h so far',
      );
    });

    test('the step a release is waiting in counts up to now', () {
      final waiting = releaseTimelines(StoreKind.appStore, [
        storeStep(
          '3.0.0',
          ReleaseState.waitingForReview,
          'Waiting for review',
          now.subtract(const Duration(hours: 7)),
        ),
      ], now: now).single;
      expect(waiting.latest.spent, const Duration(hours: 7));
      expect(waiting.reviewTime, isNull);
    });

    test('testing tracks are left off the public timeline', () {
      final timelines = releaseTimelines(StoreKind.googlePlay, [
        ...playSteps(),
        storeStep(
          '2.1.0',
          ReleaseState.testing,
          'In testing',
          now,
          track: 'beta',
          build: '21',
        ),
      ], now: now);
      expect(timelines.map((t) => t.version), ['2.0.0']);
    });
  });

  test('the usual review time is the mean of the last releases reviewed', () {
    final usual = usualReviewTime(
      releaseTimelines(StoreKind.appStore, appleSteps(), now: now),
    )!;
    expect(usual.usual, const Duration(hours: 28));
    expect(usual.over, 2);
    expect(
      usualReviewSentence(StoreKind.appStore, usual),
      'Apple review: usually 1d 4h (last 2 releases)',
    );
    expect(usualReviewTime(const []), isNull);
  });

  group('StoreReleaseTimelines', () {
    final iosApp = storeApp(StoreKind.appStore, 'com.example.notes');
    final playApp = storeApp(StoreKind.googlePlay, 'com.example.notes');
    final group = StoreAppGroup(
      bundleId: 'com.example.notes',
      entries: [
        StoreEntry(iosApp, storeSnapshot(iosApp)),
        StoreEntry(playApp, storeSnapshot(playApp)),
      ],
    );
    final history = StoreHistoryView(
      keptDays: 365,
      apps: [
        StoreAppHistory(app: iosApp, steps: appleSteps()),
        StoreAppHistory(app: playApp, steps: playSteps()),
      ],
    );

    Future<void> pump(WidgetTester tester, StoreHistoryView view) async {
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
                child: StoreReleaseTimelines(group: group),
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
          await pump(tester, history);
          expect(tester.takeException(), isNull);
          expect(
            find.text('Apple review: usually 1d 4h (last 2 releases)'),
            findsOneWidget,
          );
          expect(
            find.text('The store says: Metadata rejected'),
            findsOneWidget,
          );
          expect(find.text('Rolling out 50%'), findsOneWidget);
          final wide = size.width >= 1000;
          expect(
            find.byKey(const ValueKey('store-timeline-across')),
            wide ? findsWidgets : findsNothing,
          );
          if (size.width < 600) {
            expect(
              find.byKey(const ValueKey('store-timeline-down')),
              findsWidgets,
            );
          }
        });
      }
    }

    testWidgets('says so when no step was kept yet', (tester) async {
      setStoreTestSurface(tester, kStoreTestSizes.first, 1.0);
      await pump(tester, const StoreHistoryView());
      expect(find.byKey(const ValueKey('store-timeline-empty')), findsOne);
    });
  });
}
