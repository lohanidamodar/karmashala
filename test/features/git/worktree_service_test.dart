import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/application/worktree_service.dart';
import 'package:chitragupta/src/features/git/data/git_service.dart';
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
}
