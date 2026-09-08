import 'package:karmashala/src/app/shell/quick_open/repo_file_index.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/git/application/git_providers.dart';
import 'package:karmashala/src/features/git/application/worktree_service.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/git/application/worktree_setup_service.dart';
import 'package:karmashala/src/features/git/data/git_service.dart';
import 'package:karmashala/src/features/git/domain/worktree_setup.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

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
      final add = runner.requests.single;
      expect(add.executable, 'git');
      expect(add.arguments, [
        '-C',
        '/home/me/app',
        'worktree',
        'add',
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

    test('runs after git made the worktree, before the index is told', () async {
      await withSetup().createForSession(
        repo: repo,
        worktreeName: 's1',
        branch: 'session/s1',
      );
      expect(order, [
        'setup',
        'moved /home/me/.karmashala-worktrees/app-s1',
      ], reason: 'the copied files are part of what has just appeared');
      expect(recorded, hasLength(1));
      expect(
        recorded.single.worktreePath,
        '/home/me/.karmashala-worktrees/app-s1',
      );
    });

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

    test('a checkout with no setting spends nothing', () async {
      configured = const WorktreeSetup();
      await withSetup().createForSession(
        repo: repo,
        worktreeName: 's1',
        branch: 'session/s1',
      );
      expect(recorded, isEmpty);
      expect(
        runner.requests.map((r) => r.arguments),
        [
          [
            '-C',
            '/home/me/app',
            'worktree',
            'add',
            '-b',
            'session/s1',
            '/home/me/.karmashala-worktrees/app-s1',
          ],
        ],
        reason: 'one process: the worktree add, and nothing else',
      );
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
