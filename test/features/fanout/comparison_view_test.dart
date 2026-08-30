import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/fanout/application/comparison_providers.dart';
import 'package:chitragupta/src/features/fanout/data/comparison_dao.dart';
import 'package:chitragupta/src/features/fanout/domain/comparison.dart';
import 'package:chitragupta/src/features/fanout/presentation/comparison_list.dart';
import 'package:chitragupta/src/features/fanout/presentation/comparison_view.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// The view has one job the service cannot do for it: read a comparison whose
/// worktrees are gone. These pump the record alone — no sessions, no git — and
/// check that the page still says who ran, what they changed and who won.

const _worktree = EnvironmentPath(
  environmentId: 'windows',
  path: r'C:\src\demo\.chitragupta-worktrees\abcd1234',
);

Comparison _seeded({bool merged = true}) => Comparison(
  id: 'cmp-1',
  repositoryId: 'r1',
  prompt: 'Make the parser faster\nand keep the tests green',
  createdAt: testTime,
  outcome: merged ? ComparisonOutcome.merged : ComparisonOutcome.pending,
  winnerCandidateId: merged ? 'cand-win' : null,
  mergedCommit: merged ? 'abc1234def5678' : null,
  finishedAt: merged ? testTime : null,
  candidates: [
    ComparisonCandidate(
      id: 'cand-win',
      comparisonId: 'cmp-1',
      position: 0,
      installationId: 'a1',
      agentId: 'claudeCode',
      launch: CandidateLaunchState.started,
      sessionId: 's-win',
      worktree: _worktree,
      branch: 'session/abcd1234',
      diff: CandidateDiffStat(
        filesChanged: 4,
        insertions: 120,
        deletions: 18,
        commits: 2,
        capturedAt: testTime,
      ),
      evidence: const CandidateEvidence(
        verdict: EvidenceVerdict.passed,
        label: '12 tests, 0 failed',
      ),
    ),
    ComparisonCandidate(
      id: 'cand-lost',
      comparisonId: 'cmp-1',
      position: 1,
      installationId: 'a2',
      agentId: 'codex',
      launch: CandidateLaunchState.started,
      sessionId: 's-lost',
      worktree: _worktree,
      branch: 'session/efgh5678',
      worktreeRemoved: true,
      diff: CandidateDiffStat(
        filesChanged: 9,
        insertions: 400,
        deletions: 260,
        capturedAt: testTime,
      ),
    ),
    const ComparisonCandidate(
      id: 'cand-dead',
      comparisonId: 'cmp-1',
      position: 2,
      installationId: 'a3',
      agentId: 'flakyCli',
      launch: CandidateLaunchState.failed,
      failure: 'Bad state: could not start flakyCli',
    ),
  ],
);

AppDatabase seedDatabase({bool merged = true}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  ComparisonDao(db).insert(_seeded(merged: merged));
  return db;
}

Future<void> pump(WidgetTester tester, AppDatabase db, Widget child) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );

void main() {
  testWidgets('a comparison reads with no session and no worktree left', (
    tester,
  ) async {
    final db = seedDatabase();
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

    // The verdict sits beside the diff stat.
    expect(find.text('12 tests, 0 failed'), findsOneWidget);
  });

  testWidgets('a candidate with nothing left offers no destructive action', (
    tester,
  ) async {
    final db = seedDatabase();
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

  testWidgets('the list shows every comparison and opens one', (tester) async {
    final db = seedDatabase(merged: false);
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
    final db = seedDatabase();
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
