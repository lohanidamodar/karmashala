import 'dart:async';

import 'package:karmashala/src/app/shell/quick_open/repo_file_index.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/git/application/worktree_setup_service.dart';
import 'package:karmashala_git/git.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import 'worktree_processes.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao envDao;
  late FakeCommandRunner runner;
  late WorktreeService service;

  setUp(() {
    db = AppDatabase.memory();
    envDao = ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    runner = FakeCommandRunner(
      responder: (_) =>
          const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      processFactory: (_) => finishedGit(),
    );
    service = WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: envDao,
    );
  });
  tearDown(() => db.close());

  test(
    'createForSession computes an environment-aware path and adds it',
    () async {
      final repo = const EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/app',
      );
      final wt = await service.createForSession(
        repo: repo,
        worktreeName: 's1',
        branch: 'session/s1',
      );

      expect(wt.path.path, '/home/me/.karmashala-worktrees/app-s1');
      expect(runner.requests.first.executable, 'git');
      expect(worktreeAddArgv(runner), [
        '-C',
        '/home/me/app',
        'worktree',
        'add',
        '--no-checkout',
        '-b',
        'session/s1',
        '/home/me/.karmashala-worktrees/app-s1',
      ]);
    },
  );

  test('unknown environment raises a GitException', () async {
    final repo = const EnvironmentPath(environmentId: 'ghost', path: '/x');
    expect(
      () =>
          service.createForSession(repo: repo, worktreeName: 's', branch: 'b'),
      throwsA(isA<GitException>()),
    );
  });

  test('remove delegates to git worktree remove', () async {
    final repo = const EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\app',
    );
    await service.remove(
      repo,
      const EnvironmentPath(environmentId: 'windows', path: r'C:\wt'),
    );
    expect(runner.requests.single.arguments, [
      '-C',
      r'C:\app',
      'worktree',
      'remove',
      r'C:\wt',
    ]);
  });

  group('a teardown runs before the worktree goes', () {
    const repo = EnvironmentPath(environmentId: 'windows', path: r'C:\app');
    const wt = EnvironmentPath(environmentId: 'windows', path: r'C:\wt');

    WorktreeService withTeardown(void Function(WorktreeSetupService) onOpen) {
      late WorktreeSetupService setup;
      setup = WorktreeSetupService(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        lookup: (_) => (
          repositoryId: 'r1',
          setup: const WorktreeSetup(teardown: ['make', 'clean']),
        ),
        record: (_) {},
        openPane: (_) {
          scheduleMicrotask(() => onOpen(setup));
          return 'teardown-pane';
        },
      );
      return WorktreeService(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        environmentDao: envDao,
        setup: setup,
        teardownBound: const Duration(milliseconds: 20),
      );
    }

    test('then git removes it, and the answer says how it went', () async {
      final result = await withTeardown(
        (setup) => setup.noteExit('teardown-pane', 0),
      ).remove(repo, wt);
      expect(result?.said, 'The teardown command finished.');
      expect(runner.requests.single.arguments, contains('remove'));
    });

    test('one still running leaves the worktree where it is', () async {
      await expectLater(
        withTeardown((_) {}).remove(repo, wt),
        throwsA(
          isA<GitException>().having(
            (e) => e.message,
            'message',
            contains('Nothing was removed'),
          ),
        ),
      );
      expect(runner.requests, isEmpty);
    });
  });

  group('the checkout-moved notice', () {
    late List<EnvironmentPath> moved;

    setUp(() {
      moved = [];
      service = WorktreeService(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        environmentDao: envDao,
        onCheckoutMoved: moved.add,
      );
    });

    test('names the worktree a create just made', () async {
      await service.createForSession(
        repo: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/app',
        ),
        worktreeName: 's1',
        branch: 'session/s1',
      );
      expect(moved.single.path, '/home/me/.karmashala-worktrees/app-s1');
    });

    test('names the worktree a remove just deleted', () async {
      await service.remove(
        const EnvironmentPath(environmentId: 'windows', path: r'C:\app'),
        const EnvironmentPath(environmentId: 'windows', path: r'C:\wt'),
      );
      expect(moved.single.path, r'C:\wt');
    });

    test('is not sent when git refused to remove the worktree', () async {
      runner.responder = (_) =>
          const CommandResult(exitCode: 1, stdout: '', stderr: 'is dirty');
      await expectLater(
        service.remove(
          const EnvironmentPath(environmentId: 'windows', path: r'C:\app'),
          const EnvironmentPath(environmentId: 'windows', path: r'C:\wt'),
        ),
        throwsA(isA<GitException>()),
      );
      expect(moved, isEmpty, reason: 'the folder is still there');
    });
  });

  test('the app wires a removal through to quick open\'s index', () async {
    // B6: `RepoFileIndex.invalidate` had no production caller at all, and a
    // worktree folder is the one change the OS watcher cannot report — it sits
    // outside every root the index is watching.
    final index = RepoFileIndex();
    addTearDown(index.dispose);
    final invalidated = <String>[];
    final subscription = index.changes.listen(invalidated.add);
    addTearDown(subscription.cancel);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
        repoFileIndexProvider.overrideWithValue(index),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(worktreeServiceProvider)
        .remove(
          const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/app',
          ),
          const EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/.karmashala-worktrees/app-s1',
          ),
        );
    await pumpEventQueue();

    // The index keys on host paths, so the WSL spelling has to be translated
    // before it means anything to it.
    expect(invalidated, [
      r'\\wsl.localhost\Ubuntu\home\me\.karmashala-worktrees\app-s1',
    ]);
  });

  group('the setup hook', () {
    late List<WorktreeSetupReport> recorded;
    late List<String> order;
    late WorktreeSetup configured;
    late Object? setupThrows;

    const repo = EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/home/me/app',
    );

    WorktreeService withSetup() => WorktreeService(
      runnerFactory: FakeCommandRunnerFactory(fallback: runner),
      environmentDao: envDao,
      onCheckoutMoved: (path) => order.add('moved ${path.path}'),
      setup: _RecordingSetup(
        runnerFactory: FakeCommandRunnerFactory(fallback: runner),
        lookup: (_) => (repositoryId: 'r1', setup: configured),
        record: recorded.add,
        onRun: () {
          order.add('setup');
          if (setupThrows != null) throw setupThrows!;
        },
      ),
    );

    setUp(() {
      recorded = [];
      order = [];
      setupThrows = null;
      configured = const WorktreeSetup(copyPaths: ['.dart_tool']);
      runner.responder = (request) {
        // `git worktree add` succeeds; `check-ignore` says the path is ignored.
        if (request.arguments.contains('check-ignore')) {
          return const CommandResult(
            exitCode: 0,
            stdout: '.dart_tool',
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      };
    });

    test(
      'runs after git made the worktree, before the index is told',
      () async {
        await withSetup().createForSession(
          repo: repo,
          worktreeName: 's1',
          branch: 'session/s1',
        );
        expect(order, [
          'setup',
          'moved /home/me/.karmashala-worktrees/app-s1',
        ], reason: 'the copied files are part of what has just appeared');
        // The setup's own report, then the same row with the stages on it.
        expect(recorded.map((r) => r.worktreePath).toSet(), hasLength(1));
        expect(
          recorded.last.worktreePath,
          '/home/me/.karmashala-worktrees/app-s1',
        );
      },
    );

    test('a setup that blows up still leaves the worktree created', () async {
      setupThrows = StateError('the database went away');
      final worktree = await withSetup().createForSession(
        repo: repo,
        worktreeName: 's1',
        branch: 'session/s1',
      );
      // git already made the directory. Throwing here would abort the session
      // launch and leave an orphan.
      expect(worktree.path.path, '/home/me/.karmashala-worktrees/app-s1');
      expect(order, ['setup', 'moved /home/me/.karmashala-worktrees/app-s1']);
    });

    test('a checkout with no setting copies nothing and opens no pane, '
        'but still records how the creation went', () async {
      configured = const WorktreeSetup();
      await withSetup().createForSession(
        repo: repo,
        worktreeName: 's1',
        branch: 'session/s1',
      );
      expect(runner.requests.map((r) => r.arguments.skip(2).first), [
        'worktree',
        'ls-files',
      ], reason: 'the add, and the submodule question; no check-ignore');
      expect(runner.startRequests.single.arguments.skip(2), [
        'checkout',
        '--progress',
      ]);
      // The one outcome row: nothing copied, no command, every stage named.
      final row = recorded.last;
      expect(row.copies, isEmpty);
      expect(row.command, isNull);
      expect(
        row.creation!.stage(WorktreeStage.setupScript).state,
        WorktreeStageState.skipped,
      );
      expect(row.creation!.outcome, WorktreeCreationOutcome.succeeded);
    });

    test('git refusing to add a worktree runs no setup at all', () async {
      runner.responder = (_) => const CommandResult(
        exitCode: 128,
        stdout: '',
        stderr: 'fatal: already exists',
      );
      await expectLater(
        withSetup().createForSession(
          repo: repo,
          worktreeName: 's1',
          branch: 'session/s1',
        ),
        throwsA(isA<GitException>()),
      );
      expect(order, isEmpty, reason: 'there is no worktree to set up');
    });

    test('an unresolvable environment reaches neither git nor the setup', () {
      expect(
        () => withSetup().createForSession(
          repo: const EnvironmentPath(environmentId: 'ghost', path: '/x'),
          worktreeName: 's',
          branch: 'b',
        ),
        throwsA(isA<GitException>()),
      );
      expect(order, isEmpty);
    });
  });
}

/// A [WorktreeSetupService] that says when it ran, so the hook's *ordering*
/// can be asserted without asserting the setup's own behaviour twice.
class _RecordingSetup extends WorktreeSetupService {
  _RecordingSetup({
    required super.runnerFactory,
    required super.lookup,
    required super.record,
    required this.onRun,
  });

  final void Function() onRun;

  @override
  Future<WorktreeSetupReport?> run({
    required ExecutionEnvironment environment,
    required EnvironmentPath repo,
    required EnvironmentPath worktree,
  }) {
    onRun();
    return super.run(environment: environment, repo: repo, worktree: worktree);
  }
}
