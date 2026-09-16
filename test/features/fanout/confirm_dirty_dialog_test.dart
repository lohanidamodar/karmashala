import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/fanout/application/fanout_service.dart';
import 'package:karmashala/src/features/fanout/data/comparison_dao.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/fanout/presentation/comparison_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import 'comparison_fixtures.dart' show worktree;

const _candidates = 9;

/// Every loser comes back dirty, so the confirm lists all of them.
class _AllDirty extends FanOutService {
  _AllDirty(super.ref);

  @override
  List<FanOutResult> resultsFor(Comparison comparison) => [
    for (final candidate in comparison.candidates)
      FanOutResult(
        session: session(id: candidate.sessionId!, worktree: worktree),
        agentId: candidate.agentId,
        repository: repository(),
        candidate: candidate,
      ),
  ];

  @override
  Future<FanOutDiscard> discardLosers(
    List<FanOutResult> results, {
    required FanOutResult winner,
    Set<String> discardUncommittedFor = const {},
  }) async => FanOutDiscard(
    removed: const [],
    failures: const [],
    kept: [
      for (final loser in results)
        if (loser.session.id != winner.session.id)
          FanOutKept(
            result: loser,
            reason: FanOutKeepReason.uncommittedChanges,
            changes: [
              for (final name in ['lib/parser.dart', 'test/parser_test.dart'])
                FileChange(
                  path: name,
                  type: FileChangeType.modified,
                  staged: false,
                  unstaged: true,
                ),
            ],
          ),
    ],
  );
}

AppDatabase _seeded() {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  ComparisonDao(db).insert(
    Comparison(
      id: 'cmp-dirty',
      repositoryId: 'r1',
      prompt: 'Make the parser faster',
      createdAt: testTime,
      outcome: ComparisonOutcome.pending,
      winnerCandidateId: 'cand-0',
      candidates: [
        for (var i = 0; i < _candidates; i++)
          ComparisonCandidate(
            id: 'cand-$i',
            comparisonId: 'cmp-dirty',
            position: i,
            installationId: 'a$i',
            agentId: 'agent$i',
            launch: CandidateLaunchState.started,
            sessionId: 's-$i',
            worktree: worktree,
            branch: 'session/$i',
          ),
      ],
    ),
  );
  return db;
}

void main() {
  testWidgets('eight dirty worktrees to confirm fit a 720x560 window', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      matrix: const [minimumWindow, minimumWindowLargeText],
      because:
          'one checkbox row per dirty worktree, each with a three-line '
          'subtitle, in a dialog that did not scroll',
      build: () {
        final db = _seeded();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            fanOutServiceProvider.overrideWith(_AllDirty.new),
            commandRunnerFactoryProvider.overrideWithValue(
              FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
            ),
            hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
          ],
        );
        addTearDown(container.dispose);
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ComparisonView(comparisonId: 'cmp-dirty', onBack: () {}),
            ),
          ),
        );
      },
      warmUp: (tester) async {
        await tester.tap(find.text('Discard losing worktrees'));
        await tester.pumpAndSettle();
        expect(
          find.text('These worktrees hold uncommitted work'),
          findsOneWidget,
        );
        expect(find.byType(CheckboxListTile), findsWidgets);
      },
    );
  });
}
