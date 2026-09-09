import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/git/application/worktree_setup_service.dart';
import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// A [Clock] pinned to [testTime].
class _FixedClock implements Clock {
  @override
  DateTime nowUtc() => testTime;
}

void main() {
  const repo = EnvironmentPath(
    environmentId: 'wsl:Ubuntu',
    path: '/home/me/app',
  );
  const worktree = EnvironmentPath(
    environmentId: 'wsl:Ubuntu',
    path: '/home/me/.karmashala-worktrees/app-s1',
  );

  late FakeCommandRunner runner;
  late List<WorktreeSetupReport> recorded;
  late List<WorktreeSetupCommand> panes;

  /// Answers `git check-ignore` with [ignored], `test -e` with [present], and
  /// lets everything else succeed.
  void world({
    Set<String> ignored = const {},
    Set<String> present = const {},
    bool gitAnswers = true,
  }) {
    runner.responder = (request) {
      if (request.executable == 'git') {
        if (!gitAnswers) {
          return const CommandResult(
            exitCode: 128,
            stdout: '',
            stderr: 'fatal: not a git repository',
          );
        }
        final asked = request.arguments
            .skipWhile((a) => a != '--')
            .skip(1)
            .where(ignored.contains);
        return CommandResult(
          exitCode: asked.isEmpty ? 1 : 0,
          stdout: asked.join('\n'),
          stderr: '',
        );
      }
      if (request.executable == 'test') {
        return CommandResult(
          exitCode: present.contains(request.arguments.last) ? 0 : 1,
          stdout: '',
          stderr: '',
        );
      }
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    };
  }

  WorktreeSetupService service({
    WorktreeSetup? setup,
    String? repositoryId = 'r1',
    bool withPane = true,
    String? paneId = 'pane-1',
    Object? paneThrows,
  }) => WorktreeSetupService(
    runnerFactory: FakeCommandRunnerFactory(fallback: runner),
    clock: _FixedClock(),
    lookup: (asked) => repositoryId == null
        ? null
        : (repositoryId: repositoryId, setup: setup ?? const WorktreeSetup()),
    record: recorded.add,
    openPane: withPane
        ? (command) {
            if (paneThrows != null) throw paneThrows;
            panes.add(command);
            return paneId;
          }
        : null,
  );

  Future<WorktreeSetupReport?> run(
    WorktreeSetupService s, {
    ExecutionEnvironment? environment,
  }) => s.run(
    environment: environment ?? wslEnv(),
    repo: repo,
    worktree: worktree,
  );

  setUp(() {
    runner = FakeCommandRunner(environmentId: 'wsl:Ubuntu');
    recorded = [];
    panes = [];
    world();
  });

  group('a checkout with nothing configured costs nothing', () {
    test('no setting: no process, no pane, no row', () async {
      expect(await run(service()), isNull);
      expect(runner.requests, isEmpty);
      expect(recorded, isEmpty);
      expect(panes, isEmpty);
    });

    test('a path that is not a recorded checkout is not an error', () async {
      expect(await run(service(repositoryId: null)), isNull);
      expect(runner.requests, isEmpty);
    });
  });

  group('the copy half runs in the repository\'s own environment', () {
    test('one check-ignore for the list, then cp inside the distro', () async {
      world(
        ignored: {'.dart_tool', 'macos/Vendor'},
        present: {'/home/me/app/.dart_tool', '/home/me/app/macos/Vendor'},
      );
      final report = await run(
        service(
          setup: const WorktreeSetup(
            copyPaths: ['.dart_tool', 'macos/Vendor'],
          ),
        ),
      );

      final git = runner.requests.where((r) => r.executable == 'git');
      expect(git, hasLength(1), reason: 'one process for the whole list');
      expect(git.single.arguments, [
        '-C',
        '/home/me/app',
        'check-ignore',
        '--',
        '.dart_tool',
        'macos/Vendor',
      ]);
      expect(
        runner.requests
            .where((r) => r.executable == 'cp')
            .map((r) => r.arguments),
        [
          [
            '-a',
            '/home/me/app/.dart_tool',
            '/home/me/.karmashala-worktrees/app-s1/.dart_tool',
          ],
          [
            '-a',
            '/home/me/app/macos/Vendor',
            '/home/me/.karmashala-worktrees/app-s1/macos/Vendor',
          ],
        ],
      );
      expect(
        report!.copies.map((c) => c.result),
        everyElement(WorktreeCopyResult.copied),
      );
      expect(report.verdict, WorktreeSetupVerdict.ok);
    });

    test('a local checkout is copied on this host, with its own paths', () async {
      // The one case that is this process's own filesystem, end to end: the
      // `/`-separated setting has to become a path this OS can open, which on
      // Windows means backslashes. A real disk is the only thing that can say
      // whether the joining was right.
      final root = Directory.systemTemp.createTempSync('wt-setup');
      addTearDown(() => removeTempDirectory(root));
      final checkout = p.join(root.path, 'app');
      final made = p.join(root.path, 'app-s1');
      Directory(p.join(checkout, 'macos', 'Vendor')).createSync(
        recursive: true,
      );
      File(p.join(checkout, 'macos', 'Vendor', 'copy_wda.sh'))
          .writeAsStringSync('#!/bin/sh\n');
      Directory(p.join(made, 'macos')).createSync(recursive: true);
      world(ignored: {'macos/Vendor'});

      final report = await WorktreeSetupService(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        clock: _FixedClock(),
        lookup: (_) => (
          repositoryId: 'r1',
          setup: const WorktreeSetup(copyPaths: ['macos/Vendor']),
        ),
        record: recorded.add,
      ).run(
        // The kind decides, never the platform — and the two local kinds are
        // the ones `hostPathMapperFor` answers with the identity mapping.
        environment: Platform.isWindows ? windowsEnv() : posixEnv(),
        repo: EnvironmentPath(environmentId: 'windows', path: checkout),
        worktree: EnvironmentPath(environmentId: 'windows', path: made),
      );

      expect(report!.copies.single.result, WorktreeCopyResult.copied);
      expect(
        File(
          p.join(made, 'macos', 'Vendor', 'copy_wda.sh'),
        ).readAsStringSync(),
        '#!/bin/sh\n',
        reason: 'PROFILE-2026-09-03: only worktrees that had this build',
      );
      // No `cp` process: the host is that filesystem.
      expect(runner.requests.where((r) => r.executable == 'cp'), isEmpty);
    });

    test('a path git tracks is refused, not copied over', () async {
      world(ignored: {'.dart_tool'});
      final report = await run(
        service(setup: const WorktreeSetup(copyPaths: ['.dart_tool', 'lib'])),
      );
      final refused = report!.copies.firstWhere((c) => c.path == 'lib');
      expect(refused.result, WorktreeCopyResult.refusedTracked);
      expect(refused.reason, contains('not ignored by git'));
      expect(
        runner.requests.where(
          (r) => r.executable == 'cp' && r.arguments.last.endsWith('lib'),
        ),
        isEmpty,
        reason: 'a refusal spends no processes on the path it refused',
      );
      expect(report.verdict, WorktreeSetupVerdict.attention);
    });

    test('git refusing the question copies nothing at all', () async {
      world(gitAnswers: false, present: {'/home/me/app/.dart_tool'});
      final report = await run(
        service(setup: const WorktreeSetup(copyPaths: ['.dart_tool'])),
      );
      expect(report!.copies.single.result, WorktreeCopyResult.unknown);
      expect(report.copies.single.reason, contains('could not be asked'));
      expect(runner.requests.where((r) => r.executable == 'cp'), isEmpty);
      expect(report.verdict, WorktreeSetupVerdict.attention);
    });

    test('a refused spelling never reaches git either', () async {
      final report = await run(
        service(setup: const WorktreeSetup(copyPaths: ['../../etc/passwd'])),
      );
      expect(report!.copies.single.result, WorktreeCopyResult.refusedPath);
      expect(report.copies.single.reason, contains('..'));
      expect(runner.requests, isEmpty);
    });

    test('a bad path does not stop the good ones beside it', () async {
      world(ignored: {'.dart_tool'}, present: {'/home/me/app/.dart_tool'});
      final report = await run(
        service(
          setup: const WorktreeSetup(copyPaths: ['/etc/passwd', '.dart_tool']),
        ),
      );
      expect(report!.copies.map((c) => c.result), [
        WorktreeCopyResult.refusedPath,
        WorktreeCopyResult.copied,
      ]);
      expect(
        runner.requests.where((r) => r.executable == 'git').single.arguments,
        isNot(contains('/etc/passwd')),
      );
    });
  });

  group('the command half runs in a pane, and is not waited for', () {
    test('the pane is opened on the argv, in the worktree', () async {
      final report = await run(
        service(setup: const WorktreeSetup(command: ['flutter', 'pub', 'get'])),
      );
      expect(panes.single.argv, ['flutter', 'pub', 'get']);
      expect(panes.single.worktree, worktree);
      expect(panes.single.environment.kind, wslEnv().kind);
      expect(panes.single.title, contains('app-s1'));
      expect(report!.command!.result, WorktreeCommandResult.running);
      expect(report.command!.paneId, 'pane-1');
      // Not awaited, and the report says so rather than implying success.
      expect(report.command!.exitCode, isNull);
      expect(report.verdict, WorktreeSetupVerdict.ok);
    });

    test('the copy happens before the pane opens', () async {
      world(ignored: {'.dart_tool'}, present: {'/home/me/app/.dart_tool'});
      var copied = false;
      final s = WorktreeSetupService(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        clock: _FixedClock(),
        lookup: (_) => (
          repositoryId: 'r1',
          setup: const WorktreeSetup(
            command: ['flutter', 'pub', 'get'],
            copyPaths: ['.dart_tool'],
          ),
        ),
        record: recorded.add,
        openPane: (command) {
          copied = runner.requests.any((r) => r.executable == 'cp');
          return 'pane-1';
        },
      );
      await run(s);
      expect(
        copied,
        isTrue,
        reason: 'pub get against a .dart_tool still arriving is the race',
      );
    });

    test('nowhere visible to run it is a refusal, not a quiet run', () async {
      final report = await run(
        service(
          setup: const WorktreeSetup(command: ['flutter', 'pub', 'get']),
          withPane: false,
        ),
      );
      expect(report!.command!.result, WorktreeCommandResult.refusedNoPane);
      expect(report.command!.reason, contains('not run'));
      expect(report.command!.command, ['flutter', 'pub', 'get']);
      expect(report.verdict, WorktreeSetupVerdict.attention);
    });

    test('a pane that could not be opened is a refusal too', () async {
      final report = await run(
        service(setup: const WorktreeSetup(command: ['make']), paneId: null),
      );
      expect(report!.command!.result, WorktreeCommandResult.refusedNoPane);
    });

    test('a launcher that throws is reported, not propagated', () async {
      final report = await run(
        service(
          setup: const WorktreeSetup(command: ['make']),
          paneThrows: StateError('no terminal'),
        ),
      );
      expect(report!.command!.result, WorktreeCommandResult.couldNotStart);
      expect(report.command!.reason, contains('no terminal'));
    });

    test('a copy-only setting says so instead of nothing', () async {
      world(ignored: {'.env'}, present: {'/home/me/app/.env'});
      final report = await run(
        service(setup: const WorktreeSetup(copyPaths: ['.env'])),
      );
      expect(report!.command!.result, WorktreeCommandResult.notConfigured);
      expect(panes, isEmpty);
      expect(report.verdict, WorktreeSetupVerdict.ok);
    });
  });

  group('the verdict is corrected when the pane\'s process stops', () {
    Future<WorktreeSetupService> started() async {
      final s = service(setup: const WorktreeSetup(command: ['make']));
      await run(s);
      return s;
    }

    test('a non-zero exit becomes a recorded failure', () async {
      final s = await started();
      final corrected = s.noteExit('pane-1', 1)!;
      expect(corrected.command!.result, WorktreeCommandResult.failed);
      expect(corrected.command!.exitCode, 1);
      expect(corrected.verdict, WorktreeSetupVerdict.attention);
      expect(recorded.last.command!.exitCode, 1, reason: 'and it is filed');
      expect(recorded, hasLength(2), reason: 'a correction, not a second run');
    });

    test('exit 0 is the only healthy answer', () async {
      final s = await started();
      expect(
        s.noteExit('pane-1', 0)!.command!.result,
        WorktreeCommandResult.succeeded,
      );
    });

    test('a code we never learned is not success', () async {
      final s = await started();
      final corrected = s.noteExit('pane-1', null)!;
      expect(
        corrected.command!.result,
        WorktreeCommandResult.stoppedWithoutCode,
      );
      expect(corrected.verdict, WorktreeSetupVerdict.attention);
    });

    test('every other pane in the app is ignored, silently', () async {
      final s = await started();
      expect(s.noteExit('some-shell', 0), isNull);
      expect(recorded, hasLength(1));
    });

    test('a pane is corrected once; a second exit writes nothing', () async {
      final s = await started();
      s.noteExit('pane-1', 1);
      expect(s.noteExit('pane-1', 1), isNull);
      expect(recorded, hasLength(2));
    });

    test('a setup with no pane leaves nothing to correct', () async {
      final s = service(
        setup: const WorktreeSetup(command: ['make']),
        withPane: false,
      );
      await run(s);
      expect(s.noteExit('pane-1', 1), isNull);
    });
  });

  test('the report carries the worktree, the environment and its age', () async {
    world(ignored: {'.dart_tool'}, present: {'/home/me/app/.dart_tool'});
    final report = await run(
      service(setup: const WorktreeSetup(copyPaths: ['.dart_tool'])),
    );
    expect(report!.repositoryId, 'r1');
    expect(report.worktreePath, worktree.path);
    expect(report.environmentId, 'wsl:Ubuntu');
    expect(report.ranAt, testTime);
    expect(recorded.single.worktreePath, worktree.path);
  });
}
