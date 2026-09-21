import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

void main() {
  group('parseGitProgress', () {
    test('reads the percentage git prints while checking out', () {
      expect(parseGitProgress('Updating files:  45% (1800/4000)'), (
        label: 'Updating files',
        percent: 45,
      ));
      expect(
        parseGitProgress('remote: Counting objects: 100% (12/12), done.'),
        (label: 'Counting objects', percent: 100),
      );
    });

    test('is null for a line that only mentions a percentage', () {
      expect(
        parseGitProgress('Preparing worktree (new branch \'b1\')'),
        isNull,
      );
      expect(parseGitProgress('fatal: disk 90% full'), isNull);
      expect(parseGitProgress('Updating files: 250%'), isNull);
    });
  });

  test('stripAnsi removes colour and carriage returns, nothing else', () {
    expect(stripAnsi('\x1B[31merror:\x1B[0m bad\r'), 'error: bad');
    expect(stripAnsi('\x1B]0;title\x07plain'), 'plain');
  });

  group('OutputTail', () {
    test('folds a run of percentages into their last line', () {
      final tail = OutputTail();
      for (var i = 0; i <= 100; i += 10) {
        tail.add('Updating files: $i% ($i/100)');
      }
      tail.add('fatal: could not write file');
      expect(tail.lines, [
        'Updating files: 100% (100/100)',
        'fatal: could not write file',
      ]);
    });

    test('keeps only the last lines, ANSI-stripped', () {
      final tail = OutputTail(capacity: 2)
        ..add('one')
        ..add('')
        ..add('\x1B[1mtwo\x1B[0m')
        ..add('three');
      expect(tail.lines, ['two', 'three']);
    });
  });

  group('WorktreeCreationRecord', () {
    test('survives the round trip a stored row takes', () {
      final record = WorktreeCreationRecord.initial()
          .withStage(
            const WorktreeStageStatus(
              stage: WorktreeStage.checkout,
              state: WorktreeStageState.failed,
              detail: 'git checkout exited 128.',
              percent: 40,
              progressLabel: 'Updating files',
              outputTail: ['fatal: unable to write'],
            ),
          )
          .skipPending('Not run: an earlier stage failed.')
          .finish(WorktreeCreationOutcome.failed, cleanup: 'Removed it.');
      final back = WorktreeCreationRecord.fromJson(record.toJson())!;
      final checkout = back.stage(WorktreeStage.checkout);
      expect(back.outcome, WorktreeCreationOutcome.failed);
      expect(back.cleanup, 'Removed it.');
      expect(checkout.state, WorktreeStageState.failed);
      expect(checkout.percent, 40);
      expect(checkout.outputTail, ['fatal: unable to write']);
      expect(back.stage(WorktreeStage.agent).state, WorktreeStageState.skipped);
    });

    test('an unreadable state reads as needing attention, never as done', () {
      final back = WorktreeCreationRecord.fromJson({
        'outcome': 'from-the-future',
        'stages': [
          {'stage': 'checkout', 'state': 'teleported'},
        ],
      })!;
      expect(back.outcome, WorktreeCreationOutcome.warning);
      expect(
        back.stage(WorktreeStage.checkout).state,
        WorktreeStageState.warning,
      );
    });
  });

  group('a setup report carrying a creation', () {
    WorktreeSetupReport running() => WorktreeSetupReport(
      repositoryId: 'r1',
      worktreePath: '/wt',
      environmentId: 'e',
      ranAt: DateTime.utc(2026, 9, 21),
      copies: const [],
      command: const WorktreeCommandVerdict(
        result: WorktreeCommandResult.running,
        reason: 'Running.',
        command: ['make'],
        paneId: 'p1',
      ),
      creation: WorktreeCreationRecord.initial()
          .withStage(
            const WorktreeStageStatus(
              stage: WorktreeStage.setupScript,
              state: WorktreeStageState.running,
            ),
          )
          .finish(WorktreeCreationOutcome.succeeded),
    );

    test('a script that exits non-zero fails its stage and the outcome', () {
      final report = running();
      final after = report.withCommand(report.command!.afterExit(2));
      expect(
        after.creation!.stage(WorktreeStage.setupScript).state,
        WorktreeStageState.failed,
      );
      expect(after.creation!.outcome, WorktreeCreationOutcome.warning);
      expect(after.verdict, WorktreeSetupVerdict.attention);
    });

    test('a script that exits 0 is done, and the outcome stays good', () {
      final report = running();
      final after = report.withCommand(report.command!.afterExit(0));
      expect(
        after.creation!.stage(WorktreeStage.setupScript).state,
        WorktreeStageState.done,
      );
      expect(after.creation!.outcome, WorktreeCreationOutcome.succeeded);
      expect(after.verdict, WorktreeSetupVerdict.ok);
    });

    test('the stages are read back out of the stored detail', () {
      final report = running();
      final back = WorktreeSetupReport.fromStored(
        repositoryId: 'r1',
        worktreePath: '/wt',
        environmentId: 'e',
        ranAt: report.ranAt,
        detail: report.toJsonString(),
      );
      expect(
        back.creation!.stage(WorktreeStage.setupScript).state,
        WorktreeStageState.running,
      );
    });

    test('a row written before staging has no creation, not a fine one', () {
      final back = WorktreeSetupReport.fromStored(
        repositoryId: 'r1',
        worktreePath: '/wt',
        environmentId: 'e',
        ranAt: DateTime.utc(2026),
        detail: '{"copies":[]}',
      );
      expect(back.creation, isNull);
    });
  });

  group('GitService.streamGit', () {
    const dir = EnvironmentPath(environmentId: 'e', path: '/wt');
    late FakeProcessHandle handle;
    late FakeCommandRunner runner;

    setUp(() {
      handle = FakeProcessHandle();
      runner = FakeCommandRunner(processFactory: (_) => handle);
    });

    test('hands every line over as it arrives, and keeps the tail', () async {
      final seen = <String>[];
      final result = GitService(
        runner,
      ).streamGit(dir, ['checkout', '--progress'], onLine: seen.add);
      await pumpEventQueue();
      handle
        ..emitStderr('Updating files:  50% (2/4)')
        ..emitStderr('Updating files: 100% (4/4), done.');
      await pumpEventQueue();
      expect(seen, hasLength(2), reason: 'seen before the process ended');
      handle.complete(0);
      final ended = await result;
      expect(ended.ok, isTrue);
      expect(ended.outputTail, ['Updating files: 100% (4/4), done.']);
      expect(runner.startRequests.single.arguments, [
        '-C',
        '/wt',
        'checkout',
        '--progress',
      ]);
    });

    test(
      'a cancel kills the process and throws, rather than returning',
      () async {
        final cancel = Completer<void>();
        final result = GitService(
          runner,
        ).streamGit(dir, ['checkout'], cancel: cancel.future);
        await pumpEventQueue();
        expect(handle.killed, isFalse);
        cancel.complete();
        await expectLater(result, throwsA(isA<GitCancelled>()));
        expect(handle.killed, isTrue);
      },
    );

    test('a finished process is not killed by a late cancel', () async {
      final cancel = Completer<void>();
      final result = GitService(
        runner,
      ).streamGit(dir, ['checkout'], cancel: cancel.future);
      handle.complete(0);
      expect((await result).ok, isTrue);
      cancel.complete();
      await pumpEventQueue();
      expect(handle.killed, isFalse);
    });

    test('silence past the idle bound stops it and says so', () async {
      final result = GitService(runner).streamGit(dir, [
        'fetch',
      ], idleTimeout: const Duration(milliseconds: 20));
      final ended = await result;
      expect(handle.killed, isTrue);
      expect(ended.stalled, isTrue);
      expect(ended.ok, isFalse);
    });
  });
}
