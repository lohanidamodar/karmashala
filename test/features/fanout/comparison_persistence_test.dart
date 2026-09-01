import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/fanout/application/comparison_providers.dart';
import 'package:karmashala/src/features/fanout/application/fanout_service.dart';
import 'package:karmashala/src/features/fanout/data/comparison_dao.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/verification/domain/verdict_attribution.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'fanout_harness.dart';

/// A fan-out that only exists in a dialog is a fan-out you lose by closing the
/// dialog. These cover the record: that it is written, that it reads back after
/// a restart, and — the part that actually matters — that it still says what
/// each agent did after the winner is merged and the losers' worktrees are
/// deleted out from under it.

const _unstaged = '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,4 @@
 context stays
-old line
+new line
+another new line
\\ No newline at end of file
''';

const _staged = '''
diff --git a/lib/b.dart b/lib/b.dart
new file mode 100644
--- /dev/null
+++ b/lib/b.dart
@@ -0,0 +1,3 @@
+one
+two
+three
''';

/// A git that answers the four questions a diff capture asks.
CommandResult Function(CommandRequest) _busyGit({
  String status = ' M lib/a.dart\nA  lib/b.dart\n?? lib/c.dart',
  String commits = '3',
}) => (request) {
  final args = request.arguments;
  CommandResult ok(String stdout) =>
      CommandResult(exitCode: 0, stdout: stdout, stderr: '');
  if (args.contains('status')) return ok(status);
  if (args.contains('diff')) {
    return ok(args.contains('--staged') ? _staged : _unstaged);
  }
  if (args.contains('--abbrev-ref')) return ok('main');
  if (args.contains('rev-list')) return ok(commits);
  if (args.contains('log')) return ok('abc1234def\x1fMe\x1fthe merge');
  return ok('');
};

/// Ends every pane so `discardLosers` is not refused for a live agent.
void stopEverything(Harness h, FanOutLaunch launched) {
  final controller = h.container.read(
    terminalSessionsControllerProvider.notifier,
  );
  for (final result in launched.started) {
    final paneId = SessionDao(h.db).getById(result.session.id)!.paneId!;
    (controller.instanceFor(paneId)! as FakeTerminalInstance)
            .livenessNotifier
            .value =
        PaneLiveness.exited;
  }
}

Future<FanOutLaunch> launchTwo(Harness h) => h.container
    .read(fanOutServiceProvider)
    .launch(
      repository: repository(),
      installations: [roverInstall, flakyInstall],
      prompt: 'make the parser faster',
    );

/// What the app sees on the next launch: a new container over the same file.
ProviderContainer afterRestart(AppDatabase db) =>
    ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);

void main() {
  group('launch writes the record', () {
    test('one comparison, one candidate per installation, in order', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await launchTwo(h);

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      expect(stored.prompt, 'make the parser faster');
      expect(stored.repositoryId, repository().id);
      expect(stored.outcome, ComparisonOutcome.pending);
      expect(stored.winnerCandidateId, isNull);
      expect(stored.archived, isFalse);
      expect(stored.candidates.map((c) => c.agentId), ['roverCli', 'flakyCli']);
      expect(stored.candidates.map((c) => c.position), [0, 1]);
      expect(stored.candidates.map((c) => c.installationId), [
        roverInstall.id,
        flakyInstall.id,
      ]);
      for (final candidate in stored.candidates) {
        expect(candidate.launch, CandidateLaunchState.started);
        expect(candidate.sessionId, isNotNull);
        expect(candidate.worktree, isNotNull);
        expect(candidate.branch, startsWith('session/'));
        expect(candidate.worktreeRemoved, isFalse);
      }
      // The launch hands back the candidates it wrote, so the dialog can act on
      // them without re-reading.
      expect(
        launched.started.map((r) => r.candidate!.id),
        stored.candidates.map((c) => c.id),
      );
    });

    test(
      'an agent that never started is a failed candidate, not a gap',
      () async {
        final h = harness(paneFailsFor: {'flakyCli'});
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await launchTwo(h);

        final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
        expect(stored.candidates, hasLength(2), reason: 'both were requested');
        final failed = stored.candidates.last;
        expect(failed.agentId, 'flakyCli');
        expect(failed.launch, CandidateLaunchState.failed);
        expect(failed.sessionId, isNull);
        expect(failed.worktree, isNull);
        expect(failed.failure, contains('could not start flakyCli'));
        // Loop 48's partial-failure result is now a row, not a string in a dialog.
        expect(launched.failures.single.candidate!.id, failed.id);
      },
    );

    test('refused input writes nothing at all', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await expectLater(
        h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall],
              prompt: 'go',
            ),
        throwsA(isA<ArgumentError>()),
      );
      expect(ComparisonDao(h.db).getAll(), isEmpty);
    });
  });

  group('it survives a restart', () {
    test(
      'a new container reads back the comparison and its candidates',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        final launched = await launchTwo(h);
        h.container.dispose();

        final restarted = afterRestart(h.db);
        addTearDown(restarted.dispose);

        final comparisons = restarted.read(comparisonsProvider);
        expect(comparisons, hasLength(1));
        expect(comparisons.single.id, launched.comparison.id);
        expect(comparisons.single.prompt, 'make the parser faster');
        expect(comparisons.single.candidates.map((c) => c.agentId), [
          'roverCli',
          'flakyCli',
        ]);
      },
    );

    test(
      'the handles to act again are rebuilt from the session rows',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        final launched = await launchTwo(h);
        h.container.dispose();

        final restarted = afterRestart(h.db);
        addTearDown(restarted.dispose);

        final stored = restarted.read(comparisonsProvider).single;
        expect(stored.id, launched.comparison.id);
        final results = restarted
            .read(fanOutServiceProvider)
            .resultsFor(stored);
        expect(results.map((r) => r.agentId), ['roverCli', 'flakyCli']);
        expect(results.first.candidate!.id, stored.candidates.first.id);
        expect(results.first.session.worktree, isNotNull);
        expect(results.first.repository.id, repository().id);
      },
    );

    test('a candidate whose session is gone keeps its record', () async {
      final h = harness();
      addTearDown(h.db.close);
      final launched = await launchTwo(h);
      final lost = launched.started.first.session.id;
      SessionDao(h.db).delete(lost);
      h.container.dispose();

      final restarted = afterRestart(h.db);
      addTearDown(restarted.dispose);

      final stored = restarted.read(comparisonsProvider).single;
      // The row is still there — it is the only account of that agent's run.
      expect(stored.candidates, hasLength(2));
      expect(stored.candidates.first.sessionId, lost);
      // But there is nothing left to merge or discard for it.
      final results = restarted.read(fanOutServiceProvider).resultsFor(stored);
      expect(results.map((r) => r.agentId), ['flakyCli']);
    });
  });

  group('diff records what the worktree showed', () {
    test(
      'files from status, lines from both diffs, commits from rev-list',
      () async {
        final h = harness(git: _busyGit());
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        final launched = await launchTwo(h);

        await h.container
            .read(fanOutServiceProvider)
            .diff(launched.started.first);

        final stat = ComparisonDao(
          h.db,
        ).getById(launched.comparison.id)!.candidates.first.diff!;
        // Three paths in `git status`; `git diff` alone would have said one, and
        // it would never have seen the untracked file at all.
        expect(stat.filesChanged, 3);
        // Two from the unstaged diff, three from the staged one. `\ No newline`
        // and the `+++`/`---` headers are not content.
        expect(stat.insertions, 5);
        expect(stat.deletions, 1);
        expect(stat.commits, 3);
        expect(stat.summary, '3 files +5 −1 · 3 commits');
      },
    );

    test('a git that cannot answer still records the lines it read', () async {
      // Everything the launch needs works; every question the *stat* asks
      // beyond the unstaged diff fails.
      final h = harness(
        git: (request) {
          final args = request.arguments;
          if (args.contains('diff') && !args.contains('--staged')) {
            return const CommandResult(
              exitCode: 0,
              stdout: _unstaged,
              stderr: '',
            );
          }
          if (args.contains('--staged') ||
              args.contains('status') ||
              args.contains('rev-list') ||
              args.contains('--abbrev-ref')) {
            return const CommandResult(exitCode: 1, stdout: '', stderr: 'nope');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall],
            prompt: 'go',
          );

      await h.container
          .read(fanOutServiceProvider)
          .diff(launched.started.first);

      final stat = ComparisonDao(
        h.db,
      ).getById(launched.comparison.id)!.candidates.first.diff!;
      expect(stat.insertions, 2);
      expect(stat.deletions, 1);
      expect(stat.commits, isNull, reason: '"could not tell", not zero');
    });
  });

  group('the outcome is recorded', () {
    test('merging a winner names it and the commit it landed on', () async {
      final h = harness(git: _busyGit(status: ''));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      final winner = launched.started.first;

      await h.container.read(fanOutServiceProvider).mergeWinner(winner);

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      expect(stored.outcome, ComparisonOutcome.merged);
      expect(stored.winnerCandidateId, winner.candidate!.id);
      expect(stored.winner!.agentId, 'roverCli');
      expect(stored.mergedCommit, 'abc1234def');
      expect(stored.finishedAt, isNotNull);
    });

    test('a refused merge leaves the comparison pending', () async {
      final h = harness(git: _busyGit());
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);

      await expectLater(
        h.container
            .read(fanOutServiceProvider)
            .mergeWinner(launched.started.first),
        throwsA(isA<StateError>()),
      );

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      expect(stored.outcome, ComparisonOutcome.pending);
      expect(stored.winnerCandidateId, isNull);
    });

    test('a winner can be named without merging anything', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);

      h.container.read(fanOutServiceProvider).markWinner(launched.started.last);

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      expect(stored.winner!.agentId, 'flakyCli');
      expect(
        stored.outcome,
        ComparisonOutcome.pending,
        reason: 'naming a winner is not merging it',
      );
    });

    test('abandoning closes it out without a merge', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);

      h.container
          .read(fanOutServiceProvider)
          .abandon(ComparisonDao(h.db).getById(launched.comparison.id)!);

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      expect(stored.outcome, ComparisonOutcome.discarded);
      expect(stored.finishedAt, isNotNull);
    });
  });

  group('the record outlives the worktree', () {
    test('a discarded loser is marked, never deleted', () async {
      final h = harness(git: _busyGit(status: ''));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      stopEverything(h, launched);

      final discard = await h.container
          .read(fanOutServiceProvider)
          .discardLosers(launched.started, winner: launched.started.first);
      expect(discard.removed, hasLength(1));

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      expect(stored.candidates, hasLength(2));
      final loser = stored.candidates.last;
      expect(loser.worktreeRemoved, isTrue);
      expect(loser.hasLiveWorktree, isFalse);
      // The path is still recorded — the row says where it *was*.
      expect(loser.worktree, isNotNull);
      expect(stored.candidates.first.worktreeRemoved, isFalse);
    });

    test('the loser keeps the last diff read from it', () async {
      final h = harness(git: _busyGit(status: ''));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      stopEverything(h, launched);

      await h.container
          .read(fanOutServiceProvider)
          .discardLosers(launched.started, winner: launched.started.first);

      final loser = ComparisonDao(
        h.db,
      ).getById(launched.comparison.id)!.candidates.last;
      // Captured on the way out, when the directory still existed.
      expect(loser.diff, isNotNull);
      expect(loser.diff!.insertions, 5);
      expect(loser.diff!.commits, 3);
    });

    test('a discarded worktree is not diffed again', () async {
      final h = harness(git: _busyGit(status: ''));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      stopEverything(h, launched);
      await h.container
          .read(fanOutServiceProvider)
          .discardLosers(launched.started, winner: launched.started.first);

      final stored = ComparisonDao(h.db).getById(launched.comparison.id)!;
      final loser = h.container
          .read(fanOutServiceProvider)
          .resultFor(stored, stored.candidates.last)!;
      final before = h.git.requests.length;

      expect(await h.container.read(fanOutServiceProvider).diff(loser), '');
      expect(
        h.git.requests.length,
        before,
        reason: 'there is no directory to ask',
      );
    });

    test('merged, discarded, restarted — and it still reads', () async {
      final h = harness(git: _busyGit(status: ''));
      addTearDown(h.db.close);
      final launched = await launchTwo(h);
      stopEverything(h, launched);
      final service = h.container.read(fanOutServiceProvider);
      await service.diff(launched.started.last);
      await service.mergeWinner(launched.started.first);
      await service.discardLosers(
        launched.started,
        winner: launched.started.first,
      );
      h.container.dispose();

      final restarted = afterRestart(h.db);
      addTearDown(restarted.dispose);
      final stored = restarted.read(comparisonsProvider).single;

      expect(stored.prompt, 'make the parser faster');
      expect(stored.outcome, ComparisonOutcome.merged);
      expect(stored.mergedCommit, 'abc1234def');
      expect(stored.winner!.agentId, 'roverCli');
      expect(stored.candidates.map((c) => c.agentId), ['roverCli', 'flakyCli']);
      final loser = stored.candidates.last;
      expect(loser.worktreeRemoved, isTrue);
      expect(loser.diff!.summary, '+5 −1 · 3 commits');
    });
  });

  group('the list', () {
    test('archived comparisons are put away, not lost', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);

      final controller = h.container.read(comparisonsProvider.notifier)
        ..archive(launched.comparison.id);
      expect(h.container.read(comparisonsProvider), isEmpty);

      controller.showArchived(true);
      expect(h.container.read(comparisonsProvider), hasLength(1));

      controller
        ..showArchived(false)
        ..archive(launched.comparison.id, archived: false);
      expect(h.container.read(comparisonsProvider), hasLength(1));
    });

    test('a comparison can be narrowed to one repository', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      await launchTwo(h);

      final dao = ComparisonDao(h.db);
      expect(dao.getAll(repositoryId: repository().id), hasLength(1));
      expect(dao.getAll(repositoryId: 'other'), isEmpty);
    });
  });

  group('the verification seam', () {
    test('a verdict round-trips, and defaults to nothing', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      final dao = ComparisonDao(h.db);
      final candidate = launched.started.first.candidate!;

      expect(candidate.evidence, isNull);
      expect(
        h.container.read(candidateEvidenceProvider)(candidate.sessionId!),
        isNull,
        reason: 'nothing offers verdicts until verification is wired in',
      );

      dao.updateEvidence(
        candidate.id,
        const CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '8 tests, 0 failed',
          runId: 'run-1',
        ),
      );

      final stored = dao.getById(launched.comparison.id)!.candidates.first;
      expect(stored.evidence!.verdict, EvidenceVerdict.passed);
      expect(stored.evidence!.label, '8 tests, 0 failed');
      expect(stored.evidence!.runId, 'run-1');
      // Nobody named a producer, so the candidate says so rather than
      // assuming the session that did the work also graded it.
      expect(stored.evidence!.producerSessionId, isNull);
      expect(stored.evidenceAttribution, VerdictAttribution.notRecorded);
    });

    test('who produced the verdict survives the round trip', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      final dao = ComparisonDao(h.db);
      final candidate = launched.started.first.candidate!;

      dao.updateEvidence(
        candidate.id,
        CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '8 tests, 0 failed',
          runId: 'run-1',
          producerSessionId: candidate.sessionId,
        ),
      );
      final self = dao.getById(launched.comparison.id)!.candidates.first;
      expect(self.evidence!.producerSessionId, candidate.sessionId);
      expect(self.evidenceAttribution, VerdictAttribution.author);

      dao.updateEvidence(
        candidate.id,
        const CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '8 tests, 0 failed',
          runId: 'run-2',
          producerSessionId: 'some-other-session',
        ),
      );
      final checked = dao.getById(launched.comparison.id)!.candidates.first;
      expect(checked.evidenceAttribution, VerdictAttribution.independent);
    });

    test('a note can be kept against a candidate', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final launched = await launchTwo(h);
      final dao = ComparisonDao(h.db)
        ..updateNotes(launched.started.last.candidate!.id, 'over-engineered');

      expect(
        dao.getById(launched.comparison.id)!.candidates.last.notes,
        'over-engineered',
      );
    });
  });
}
