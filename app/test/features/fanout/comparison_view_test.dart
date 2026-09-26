import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/fanout/application/comparison_providers.dart';
import 'package:karmashala/src/features/fanout/data/comparison_dao.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_chrome.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_list.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import 'comparison_fixtures.dart';

/// The view has one job the service cannot do for it: read a comparison whose
/// worktrees are gone. These pump the record alone — no sessions, no git — and
/// check that the page still says who ran, what they changed and who won.

void main() {
  // Where each test's project and repository live; the view reads the
  // repository's name through a client of it.
  late FakeDataServer server;
  setUp(() => server = FakeDataServer());

  Future<void> pump(WidgetTester tester, AppDatabase db, Widget child) async =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            await server.override(),
          ],
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  testWidgets('a comparison reads with no session and no worktree left', (
    tester,
  ) async {
    final db = seedDatabase(server: server);
    addTearDown(db.close);

    await pump(
      tester,
      db,
      ComparisonView(comparisonId: 'cmp-1', onBack: () {}),
    );

    // The prompt, every agent, and the outcome.
    expect(find.textContaining('Make the parser faster'), findsOneWidget);
    expect(find.text('claudeCode'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);
    expect(find.text('flakyCli'), findsOneWidget);
    expect(find.textContaining('merged abc1234'), findsOneWidget);
    expect(find.text('Winner: claudeCode'), findsOneWidget);

    // The loser's directory is gone; its account of itself is not.
    expect(find.text('worktree removed  ·  branch kept'), findsOneWidget);
    expect(
      find.textContaining(
        'The worktree is gone. The stat above is what it last showed.',
      ),
      findsOneWidget,
    );

    // Loop 48's partial failure, as a candidate rather than a banner.
    expect(find.text('Bad state: could not start flakyCli'), findsOneWidget);
    expect(
      find.text('Nothing ran, so there is nothing to diff.'),
      findsOneWidget,
    );

    // The verdict sits beside the diff stat, and says who produced it —
    // here nobody did, which reads as its own answer. The outcome says it too,
    // because the merge is what was decided on the strength of that verdict.
    expect(find.text('12 tests, 0 failed'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(VerdictChip),
        matching: find.text('unattributed'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(OutcomeLabel),
        matching: find.text('unattributed'),
      ),
      findsOneWidget,
    );
  });

  /// Rewrites `cand-win`'s verdict so only the producer differs, and renders.
  Future<void> pumpWithProducer(
    WidgetTester tester,
    AppDatabase db,
    String? producerSessionId,
  ) async {
    ComparisonDao(db).updateEvidence(
      'cand-win',
      CandidateEvidence(
        verdict: EvidenceVerdict.passed,
        label: '12 tests, 0 failed',
        producerSessionId: producerSessionId,
      ),
    );
    await pump(
      tester,
      db,
      ComparisonView(comparisonId: 'cmp-1', onBack: () {}),
    );
  }

  testWidgets('a candidate that graded its own work is labelled self', (
    tester,
  ) async {
    final db = seedDatabase(server: server);
    addTearDown(db.close);
    // s-win is cand-win's own session.
    await pumpWithProducer(tester, db, 's-win');

    // Both the candidate's chip and the merged outcome above it.
    expect(find.text('self'), findsNWidgets(2));
    expect(find.text('independent'), findsNothing);
  });

  testWidgets('a verdict from another session is labelled independent', (
    tester,
  ) async {
    final db = seedDatabase(server: server);
    addTearDown(db.close);
    await pumpWithProducer(tester, db, 's-lost');

    expect(find.text('independent'), findsNWidgets(2));
    expect(find.text('self'), findsNothing);
  });

  testWidgets('a candidate with nothing left offers no destructive action', (
    tester,
  ) async {
    final db = seedDatabase(server: server);
    addTearDown(db.close);

    await pump(
      tester,
      db,
      ComparisonView(comparisonId: 'cmp-1', onBack: () {}),
    );

    // No session rows exist, so nothing can be merged from this record.
    for (final button in tester.widgetList<FilledButton>(
      find.widgetWithText(FilledButton, 'Merge'),
    )) {
      expect(button.onPressed, isNull);
    }
    for (final button in tester.widgetList<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Winner'),
    )) {
      expect(button.onPressed, isNull);
    }
  });

  group('candidate columns share the width they are given', () {
    Rect columnOf(WidgetTester tester, String agent) => tester.getRect(
      find
          .ancestor(
            of: find.text(agent),
            matching: find.byWidgetPredicate(
              (w) => w is SizedBox && (w.width ?? 0) >= 300,
            ),
          )
          .first,
    );

    Future<void> pumpAt(WidgetTester tester, Size size) async {
      final db = seedDatabase(server: server);
      addTearDown(db.close);
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        db,
        ComparisonView(comparisonId: 'cmp-1', onBack: () {}),
      );
    }

    testWidgets('two whole columns at the minimum window', (tester) async {
      await pumpAt(tester, const Size(720, 560));
      expect(columnOf(tester, 'claudeCode').width, 300);
      expect(
        columnOf(tester, 'codex').right,
        lessThanOrEqualTo(720),
        reason: 'a fixed 372 left 1.8 columns visible at 720',
      );
    });

    testWidgets('and all three fill a desktop window', (tester) async {
      await pumpAt(tester, const Size(1440, 900));
      final first = columnOf(tester, 'claudeCode');
      final last = columnOf(tester, 'flakyCli');
      expect(first.width, closeTo((1440 - 2 * 16) / 3, 0.01));
      expect(last.right, closeTo(1440, 0.01));
    });
  });

  testWidgets('an empty list and an empty comparison are pane placeholders', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await pump(tester, db, ComparisonList(onOpen: (_) {}, onNew: () {}));
    expect(find.byType(PanePlaceholder), findsOneWidget);
    expect(find.textContaining('No comparisons yet'), findsOneWidget);

    final seeded = seedDatabase(server: server);
    addTearDown(seeded.close);
    ComparisonDao(seeded).insert(
      Comparison(
        id: 'cmp-empty',
        repositoryId: 'r1',
        prompt: 'Nobody answered',
        createdAt: testTime,
        outcome: ComparisonOutcome.pending,
        candidates: const [],
      ),
    );
    await pump(
      tester,
      seeded,
      ComparisonView(comparisonId: 'cmp-empty', onBack: () {}),
    );
    expect(find.byType(PanePlaceholder), findsOneWidget);
    expect(find.text('No candidates were recorded.'), findsOneWidget);
  });

  testWidgets('the list shows every comparison and opens one', (tester) async {
    final db = seedDatabase(merged: false, server: server);
    addTearDown(db.close);
    String? opened;

    await pump(
      tester,
      db,
      ComparisonList(onOpen: (id) => opened = id, onNew: () {}),
    );

    expect(find.text('Fan-out comparisons'), findsOneWidget);
    expect(find.text('Make the parser faster'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    expect(find.text('app  ·  ${shortAgeOf(testTime)}'), findsOneWidget);

    await tester.tap(find.text('Make the parser faster'));
    expect(opened, 'cmp-1');
  });

  testWidgets('archiving takes a comparison out of the list', (tester) async {
    final db = seedDatabase(server: server);
    addTearDown(db.close);
    late WidgetRef captured;

    await pump(
      tester,
      db,
      Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return ComparisonList(onOpen: (_) {}, onNew: () {});
        },
      ),
    );
    expect(find.text('Make the parser faster'), findsOneWidget);

    captured.read(comparisonsProvider.notifier).archive('cmp-1');
    await tester.pump();
    expect(find.text('Make the parser faster'), findsNothing);

    await tester.tap(find.text('Show archived'));
    await tester.pump();
    expect(find.text('Make the parser faster'), findsOneWidget);
    expect(find.textContaining('archived'), findsWidgets);
  });
}

/// Mirrors the view's own age formatting so the row assertion is not a date.
String shortAgeOf(DateTime when) {
  final days = DateTime.now().toUtc().difference(when).inDays;
  return days < 30
      ? '${days}d ago'
      : '${when.toLocal().year}-'
            '${when.toLocal().month.toString().padLeft(2, '0')}-'
            '${when.toLocal().day.toString().padLeft(2, '0')}';
}
