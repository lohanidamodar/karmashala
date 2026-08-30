import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/agents/domain/agent_installation.dart';
import 'package:chitragupta/src/features/fanout/application/fanout_service.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_naming.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'fanout_harness.dart';

/// Parallel worktree fan-out: run one prompt on several agents at once, compare
/// their diffs, merge one, discard the rest.
///
/// The feature shipped with no tests at all. These cover the four things it
/// decides — what input it refuses, what it does when only *some* agents start,
/// what it will merge, and what it will delete.

void main() {
  group('validation refuses before anything is created', () {
    late Harness h;
    setUp(() => h = harness());
    tearDown(() {
      h.container.dispose();
      h.db.close();
    });

    Future<FanOutLaunch> run({
      String prompt = 'do the thing',
      List<AgentInstallation>? installations,
    }) => h.container
        .read(fanOutServiceProvider)
        .launch(
          repository: repository(),
          installations: installations ?? [roverInstall, flakyInstall],
          prompt: prompt,
        );

    test('an empty prompt is refused', () async {
      await expectLater(run(prompt: ''), throwsA(isA<ArgumentError>()));
      expect(h.git.requests, isEmpty);
      expect(SessionDao(h.db).getAll(), isEmpty);
    });

    test('a whitespace-only prompt is refused', () async {
      await expectLater(run(prompt: '   \n  '), throwsA(isA<ArgumentError>()));
      expect(h.git.requests, isEmpty);
    });

    test('fewer than two installations is not a comparison', () async {
      await expectLater(
        run(installations: [roverInstall]),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        run(installations: const []),
        throwsA(isA<ArgumentError>()),
      );
      expect(h.git.requests, isEmpty);
    });

    test('the same installation twice is refused', () async {
      await expectLater(
        run(installations: [roverInstall, roverInstall]),
        throwsA(isA<ArgumentError>()),
      );
      expect(h.git.requests, isEmpty);
    });

    test('two installations of the same agent are allowed', () async {
      final launched = await run(
        installations: [roverInstall, secondRoverInstall],
      );
      expect(launched.started, hasLength(2));
      expect(launched.failures, isEmpty);
    });
  });

  group('launch', () {
    test(
      'gives every agent its own worktree on its own session branch',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall, flakyInstall],
              prompt: 'refactor the parser',
            );

        expect(launched.started, hasLength(2));
        expect(launched.failures, isEmpty);
        expect(launched.hasFailures, isFalse);
        expect(launched.partialSummary, isNull);
        expect(launched.requested, 2);
        expect(launched.started.map((r) => r.agentId), [
          'roverCli',
          'flakyCli',
        ]);

        // Two worktrees, each on the branch its session names.
        final adds = h.git.requests
            .where((r) => r.arguments.contains('add'))
            .toList();
        expect(adds, hasLength(2));
        for (final result in launched.started) {
          expect(result.session.worktree, isNotNull);
          expect(
            adds.any(
              (a) => a.arguments.contains(sessionBranchName(result.session.id)),
            ),
            isTrue,
            reason: 'a worktree on this session\'s branch',
          );
        }
      },
    );

    test('sends the trimmed prompt to every agent', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall],
            prompt: '  compare these  ',
          );

      final controller = h.container.read(
        terminalSessionsControllerProvider.notifier,
      );
      for (final result in launched.started) {
        final paneId = SessionDao(h.db).getById(result.session.id)!.paneId!;
        final instance =
            controller.instanceFor(paneId)! as FakeTerminalInstance;
        expect(instance.agentLaunch!.arguments, contains('compare these'));
      }
    });
  });

  group('a partial launch keeps what started', () {
    test('the agents that started are returned, not discarded', () async {
      final h = harness(paneFailsFor: {'flakyCli'});
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall, secondRoverInstall],
            prompt: 'go',
          );

      // This is the bug: `Future.wait` threw here and took the two running
      // sessions with it, leaving them alive and unreferenced.
      expect(launched.started.map((r) => r.agentId), ['roverCli', 'roverCli']);
      expect(launched.failures.map((f) => f.agentId), ['flakyCli']);
      expect(launched.requested, 3);
      expect(launched.hasFailures, isTrue);
      expect(launched.partialSummary, '2 of 3 agents started; 1 failed.');
    });

    test('the failure names the installation and carries the error', () async {
      final h = harness(paneFailsFor: {'flakyCli'});
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final launched = await h.container
          .read(fanOutServiceProvider)
          .launch(
            repository: repository(),
            installations: [roverInstall, flakyInstall],
            prompt: 'go',
          );

      final failure = launched.failures.single;
      expect(failure.installation.id, flakyInstall.id);
      expect('${failure.error}', contains('could not start flakyCli'));
    });

    test(
      'the started sessions are running rows; the failed one is failed',
      () async {
        final h = harness(paneFailsFor: {'flakyCli'});
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall, flakyInstall],
              prompt: 'go',
            );

        final dao = SessionDao(h.db);
        expect(
          dao.getById(launched.started.single.session.id)!.status,
          SessionStatus.running,
        );
        expect(
          dao.getAll().where((s) => s.status == SessionStatus.failed),
          hasLength(1),
        );
      },
    );

    test(
      'every agent failing is a launch with no results, not a throw',
      () async {
        final h = harness(paneFailsFor: {'roverCli', 'flakyCli'});
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final launched = await h.container
            .read(fanOutServiceProvider)
            .launch(
              repository: repository(),
              installations: [roverInstall, flakyInstall],
              prompt: 'go',
            );

        expect(launched.started, isEmpty);
        expect(launched.failures, hasLength(2));
        expect(launched.partialSummary, '0 of 2 agents started; 2 failed.');
      },
    );
  });

  group('diff', () {
    test('asks git for the worktree\'s diff', () async {
      final h = harness(
        git: (request) => request.arguments.contains('diff')
            ? const CommandResult(
                exitCode: 0,
                stdout: 'diff --git a/x b/x',
                stderr: '',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );

      final result = launched.started.first;
      expect(await service.diff(result), 'diff --git a/x b/x');
      final diffCall = h.git.requests.lastWhere(
        (r) => r.arguments.contains('diff'),
      );
      expect(diffCall.arguments, contains(result.session.worktree!.path));
    });

    test(
      'a result with no worktree diffs to nothing rather than throwing',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);

        final result = FanOutResult(
          session: session(id: 'no-wt'),
          agentId: 'roverCli',
          repository: repository(),
        );
        expect(await h.container.read(fanOutServiceProvider).diff(result), '');
      },
    );
  });

  group('mergeWinner', () {
    test('refuses a winner with uncommitted changes', () async {
      final h = harness(git: _gitWithStatus(' M lib/main.dart'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );

      await expectLater(
        service.mergeWinner(launched.started.first),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('still has uncommitted changes'),
          ),
        ),
      );
      // And nothing was merged.
      expect(
        h.git.requests.where((r) => r.arguments.contains('merge')),
        isEmpty,
      );
    });

    test('merges the session branch when the worktree is clean', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );
      final winner = launched.started.first;

      await service.mergeWinner(winner);

      final merge = h.git.requests.lastWhere(
        (r) => r.arguments.contains('merge'),
      );
      expect(merge.arguments, contains(repository().path.path));
      expect(merge.arguments, contains(sessionBranchName(winner.session.id)));
    });

    test('refuses a result that has no worktree', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      await expectLater(
        h.container
            .read(fanOutServiceProvider)
            .mergeWinner(
              FanOutResult(
                session: session(id: 'no-wt'),
                agentId: 'roverCli',
                repository: repository(),
              ),
            ),
        throwsA(isA<StateError>()),
      );
    });

    test('merging alone removes nothing', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);

      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );

      await service.mergeWinner(launched.started.first);

      // The losing worktrees are still there: discarding them is a separate,
      // deliberate act, not a side effect of picking a winner.
      expect(
        h.git.requests.where((r) => r.arguments.contains('remove')),
        isEmpty,
      );
    });
  });

  group('discardLosers', () {
    /// Launches two agents and ends both panes, so nothing is running.
    Future<(FanOutService, FanOutLaunch)> launchedAndStopped(Harness h) async {
      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );
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
      return (service, launched);
    }

    test('removes the losers and keeps the winner', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final (service, launched) = await launchedAndStopped(h);
      final winner = launched.started.first;
      final loser = launched.started.last;

      final discard = await service.discardLosers(
        launched.started,
        winner: winner,
      );

      expect(discard.removed.map((r) => r.session.id), [loser.session.id]);
      expect(discard.kept, isEmpty);
      expect(discard.failures, isEmpty);

      final removes = h.git.requests
          .where((r) => r.arguments.contains('remove'))
          .toList();
      expect(removes, hasLength(1));
      expect(removes.single.arguments, contains(loser.session.worktree!.path));
      expect(removes.single.arguments, isNot(contains('--force')));
      // The winner's worktree is untouched.
      expect(
        removes.single.arguments,
        isNot(contains(winner.session.worktree!.path)),
      );
    });

    test('keeps a loser that still has uncommitted work', () async {
      final h = harness(git: _gitWithStatus(' M lib/main.dart'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final (service, launched) = await launchedAndStopped(h);

      final discard = await service.discardLosers(
        launched.started,
        winner: launched.started.first,
      );

      expect(discard.removed, isEmpty);
      final kept = discard.kept.single;
      expect(kept.reason, FanOutKeepReason.uncommittedChanges);
      expect(kept.changes.single.path, 'lib/main.dart');
      expect(
        h.git.requests.where((r) => r.arguments.contains('remove')),
        isEmpty,
        reason: 'nothing may be deleted without being confirmed',
      );
    });

    test('removes uncommitted work only for the session named', () async {
      final h = harness(git: _gitWithStatus(' M lib/main.dart'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final (service, launched) = await launchedAndStopped(h);
      final loser = launched.started.last;

      final discard = await service.discardLosers(
        launched.started,
        winner: launched.started.first,
        discardUncommittedFor: {loser.session.id},
      );

      expect(discard.removed.map((r) => r.session.id), [loser.session.id]);
      final remove = h.git.requests.lastWhere(
        (r) => r.arguments.contains('remove'),
      );
      // Git will not remove a dirty worktree without this, and it is only
      // reached for a session the caller confirmed.
      expect(remove.arguments, contains('--force'));
    });

    test('confirming one session does not license another', () async {
      final h = harness(git: _gitWithStatus(' M lib/main.dart'));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall, secondRoverInstall],
        prompt: 'go',
      );
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

      final discard = await service.discardLosers(
        launched.started,
        winner: launched.started.first,
        discardUncommittedFor: {launched.started[1].session.id},
      );

      expect(discard.removed.map((r) => r.session.id), [
        launched.started[1].session.id,
      ]);
      expect(
        discard.kept.single.result.session.id,
        launched.started[2].session.id,
      );
    });

    test('refuses to delete a worktree an agent is still working in', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall],
        prompt: 'go',
      );

      // Panes left live, which is what they are right after a fan-out.
      final discard = await service.discardLosers(
        launched.started,
        winner: launched.started.first,
      );

      expect(discard.removed, isEmpty);
      expect(discard.kept.single.reason, FanOutKeepReason.stillRunning);
      expect(
        h.git.requests.where((r) => r.arguments.contains('remove')),
        isEmpty,
      );
    });

    test('a git failure is reported, and does not stop the others', () async {
      final h = harness(
        git: (request) => request.arguments.contains('remove')
            ? const CommandResult(
                exitCode: 128,
                stdout: '',
                stderr: 'fatal: nope',
              )
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final service = h.container.read(fanOutServiceProvider);
      final launched = await service.launch(
        repository: repository(),
        installations: [roverInstall, flakyInstall, secondRoverInstall],
        prompt: 'go',
      );
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

      final discard = await service.discardLosers(
        launched.started,
        winner: launched.started.first,
      );

      expect(discard.removed, isEmpty);
      expect(discard.failures, hasLength(2));
      expect('${discard.failures.first.error}', contains('fatal: nope'));
      // Both were attempted: one failing loser does not abandon the rest.
      expect(
        h.git.requests.where((r) => r.arguments.contains('remove')),
        hasLength(2),
      );
    });

    test('a result with no worktree is nothing to discard', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      final service = h.container.read(fanOutServiceProvider);

      final winner = FanOutResult(
        session: session(id: 'w'),
        agentId: 'roverCli',
        repository: repository(),
      );
      final discard = await service.discardLosers([
        winner,
        FanOutResult(
          session: session(id: 'l'),
          agentId: 'flakyCli',
          repository: repository(),
        ),
      ], winner: winner);

      expect(discard.isEmpty, isTrue);
      expect(h.git.requests, isEmpty);
    });
  });

  group('sessionNaming', () {
    test('the branch and the worktree share one short id', () {
      const id = '0123456789abcdef';
      expect(sessionShortId(id), '01234567');
      expect(sessionWorktreeName(id), '01234567');
      expect(sessionBranchName(id), 'session/01234567');
    });

    test('an id shorter than the handle is used whole, not thrown on', () {
      expect(sessionShortId('s-0'), 's-0');
      expect(sessionBranchName('s-0'), 'session/s-0');
    });
  });
}

CommandResult Function(CommandRequest) _gitWithStatus(String porcelain) =>
    (request) => request.arguments.contains('status')
    ? CommandResult(exitCode: 0, stdout: porcelain, stderr: '')
    : const CommandResult(exitCode: 0, stdout: '', stderr: '');
