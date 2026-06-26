import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/git/data/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';

void main() {
  EnvironmentPath repo(String path, [String env = 'windows']) =>
      EnvironmentPath(environmentId: env, path: path);

  group('parseWorktreeList', () {
    test('parses multiple worktrees with branches and bare entry', () {
      const out = '''
worktree /repo
HEAD aaaa
branch refs/heads/main

worktree /repo-wt/feature
HEAD bbbb
branch refs/heads/feature/x

worktree /bare
bare
''';
      final list = parseWorktreeList(out, 'wsl:Ubuntu');
      expect(list.length, 3);
      expect(list[0].branch, 'main');
      expect(list[0].path.path, '/repo');
      expect(list[0].path.environmentId, 'wsl:Ubuntu');
      expect(list[1].branch, 'feature/x');
      expect(list[2].isBare, isTrue);
      expect(list[2].branch, isNull);
    });

    test('empty output yields no worktrees', () {
      expect(parseWorktreeList('', 'windows'), isEmpty);
    });
  });

  group('worktreePathFor', () {
    test('Windows uses backslash separators in a sibling folder', () {
      final wt = worktreePathFor(
        EnvironmentKind.windowsNative,
        repo(r'C:\src\app'),
        'fix-bug',
      );
      expect(wt.path, r'C:\src\.chitragupta-worktrees\app-fix-bug');
      expect(wt.environmentId, 'windows');
    });

    test('WSL uses POSIX separators', () {
      final wt = worktreePathFor(
        EnvironmentKind.wsl,
        repo('/home/me/app', 'wsl:Ubuntu'),
        'fix-bug',
      );
      expect(wt.path, '/home/me/.chitragupta-worktrees/app-fix-bug');
    });
  });

  group('GitService', () {
    test('listWorktrees runs git -C and parses output', () async {
      final runner = FakeCommandRunner(
        responder: (req) {
          expect(req.executable, 'git');
          expect(req.arguments, [
            '-C',
            r'C:\src\app',
            'worktree',
            'list',
            '--porcelain',
          ]);
          return const CommandResult(
            exitCode: 0,
            stdout: 'worktree /repo\nbranch refs/heads/main\n',
            stderr: '',
          );
        },
      );
      final list = await GitService(runner).listWorktrees(repo(r'C:\src\app'));
      expect(list.single.branch, 'main');
    });

    test(
      'addWorktree builds the add command and returns the worktree',
      () async {
        late CommandRequest captured;
        final runner = FakeCommandRunner(
          responder: (req) {
            captured = req;
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          },
        );
        final wt = await GitService(runner).addWorktree(
          repo(r'C:\src\app'),
          worktreePath: repo(r'C:\src\.wt\app-x'),
          branch: 'feature/x',
          baseRef: 'main',
        );
        expect(captured.arguments, [
          '-C',
          r'C:\src\app',
          'worktree',
          'add',
          '-b',
          'feature/x',
          r'C:\src\.wt\app-x',
          'main',
        ]);
        expect(wt.branch, 'feature/x');
      },
    );

    test('addWorktree throws GitException on failure', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 128,
          stdout: '',
          stderr: 'fatal: branch exists',
        ),
      );
      expect(
        () => GitService(runner).addWorktree(
          repo(r'C:\src\app'),
          worktreePath: repo(r'C:\src\.wt\x'),
          branch: 'x',
        ),
        throwsA(isA<GitException>()),
      );
    });

    test('removeWorktree passes --force when requested', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitService(
        runner,
      ).removeWorktree(repo(r'C:\src\app'), repo(r'C:\src\.wt\x'), force: true);
      expect(captured.arguments, [
        '-C',
        r'C:\src\app',
        'worktree',
        'remove',
        '--force',
        r'C:\src\.wt\x',
      ]);
    });

    test('currentBranch returns the branch name', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: 'main\n', stderr: ''),
      );
      expect(
        await GitService(runner).currentBranch(repo(r'C:\src\app')),
        'main',
      );
    });

    test('isGitRepository true when inside a work tree', () async {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: 'true\n', stderr: ''),
      );
      expect(
        await GitService(runner).isGitRepository(repo(r'C:\src\app')),
        isTrue,
      );
    });

    test('commit stages nothing itself; commit runs git commit -m', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitService(runner).commit(repo(r'C:\app'), 'msg');
      expect(captured.arguments, ['-C', r'C:\app', 'commit', '-m', 'msg']);
    });

    test('push sets upstream when remote and branch are given', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitService(
        runner,
      ).push(repo(r'C:\app'), remote: 'origin', branch: 'main');
      expect(captured.arguments, [
        '-C',
        r'C:\app',
        'push',
        '-u',
        'origin',
        'main',
      ]);
    });
  });
}
