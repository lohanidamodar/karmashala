import 'package:chitragupta/src/app/shell/quick_open/repo_file_index.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/application/git_providers.dart';
import 'package:chitragupta/src/features/git/application/worktree_service.dart';
import 'package:chitragupta/src/features/git/data/git_service.dart';
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

      expect(wt.path.path, '/home/me/.chitragupta-worktrees/app-s1');
      final add = runner.requests.single;
      expect(add.executable, 'git');
      expect(add.arguments, [
        '-C',
        '/home/me/app',
        'worktree',
        'add',
        '-b',
        'session/s1',
        '/home/me/.chitragupta-worktrees/app-s1',
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
      expect(moved.single.path, '/home/me/.chitragupta-worktrees/app-s1');
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
            path: '/home/me/.chitragupta-worktrees/app-s1',
          ),
        );
    await pumpEventQueue();

    // The index keys on host paths, so the WSL spelling has to be translated
    // before it means anything to it.
    expect(invalidated, [
      r'\\wsl.localhost\Ubuntu\home\me\.chitragupta-worktrees\app-s1',
    ]);
  });
}
