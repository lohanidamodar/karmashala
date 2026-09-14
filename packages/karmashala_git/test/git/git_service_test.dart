import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

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
      expect(wt.path, r'C:\src\.karmashala-worktrees\app-fix-bug');
      expect(wt.environmentId, 'windows');
    });

    test('WSL uses POSIX separators', () {
      final wt = worktreePathFor(
        EnvironmentKind.wsl,
        repo('/home/me/app', 'wsl:Ubuntu'),
        'fix-bug',
      );
      expect(wt.path, '/home/me/.karmashala-worktrees/app-fix-bug');
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

    test('a push is bounded, a read is not', () async {
      // A credential prompt nobody can see, or a stalled remote, used to hold
      // the caller forever: no request carried a timeout.
      final requests = <CommandRequest>[];
      final runner = FakeCommandRunner(
        responder: (req) {
          requests.add(req);
          return const CommandResult(exitCode: 0, stdout: 'main', stderr: '');
        },
      );
      final service = GitService(
        runner,
        networkTimeout: const Duration(seconds: 7),
        mutationTimeout: const Duration(seconds: 3),
      );
      await service.push(repo(r'C:\app'));
      await service.currentBranch(repo(r'C:\app'));
      await service.commit(repo(r'C:\app'), 'm');

      expect(requests[0].timeout, const Duration(seconds: 7));
      expect(requests[1].timeout, isNull);
      expect(requests[2].timeout, const Duration(seconds: 3));
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

    test('diffStat compares the working tree to HEAD by default', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout: '4\t1\tlib/a.dart\n',
            stderr: '',
          );
        },
      );
      final stat = await GitService(runner).diffStat(repo(r'C:\app'));
      expect(captured.arguments, [
        '-C',
        r'C:\app',
        'diff',
        '--numstat',
        'HEAD',
      ]);
      expect(stat, const DiffStat(added: 4, removed: 1, files: 1));
    });

    test('diffStat against a base covers committed and uncommitted work in one '
        'process', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitService(runner).diffStat(repo(r'C:\app'), base: 'main');
      expect(captured.arguments.last, 'main');
    });

    test('diffStat says "could not tell" rather than zero when git fails', () {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 128, stdout: '', stderr: 'fatal'),
      );
      expect(GitService(runner).diffStat(repo(r'C:\app')), completion(isNull));
    });

    test('fileDiffStats asks the same one question, keyed by file', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(
            exitCode: 0,
            stdout: '4\t1\tlib/a.dart\n-\t-\tassets/i.png\n',
            stderr: '',
          );
        },
      );
      final stats = await GitService(runner).fileDiffStats(repo(r'C:\app'));
      expect(captured.arguments, [
        '-C',
        r'C:\app',
        'diff',
        '--numstat',
        'HEAD',
      ]);
      expect(stats, {
        'lib/a.dart': const FileDiffStat(added: 4, removed: 1),
        'assets/i.png': FileDiffStat.binary,
      });
    });

    test('fileDiffStats against a base asks about that base', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );
      await GitService(runner).fileDiffStats(repo(r'C:\app'), base: 'main');
      expect(captured.arguments.last, 'main');
    });

    test('fileDiffStats shows no counts rather than failing when git does', () {
      // Empty and "could not tell" are the same to this caller on purpose: the
      // sidebar draws the listing either way.
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 128, stdout: '', stderr: 'fatal'),
      );
      expect(
        GitService(runner).fileDiffStats(repo(r'C:\app')),
        completion(isEmpty),
      );
    });

    test('aheadBehind asks for both counts once', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 0, stdout: '1\t4\n', stderr: '');
        },
      );
      final result = await GitService(
        runner,
      ).aheadBehind(repo(r'C:\app'), base: 'origin/main');
      expect(captured.arguments, [
        '-C',
        r'C:\app',
        'rev-list',
        '--left-right',
        '--count',
        'origin/main...HEAD',
      ]);
      expect(result, const AheadBehind(ahead: 4, behind: 1));
    });

    test(
      'upstreamOf reads the branch ref, with no braces in the arguments',
      () async {
        late CommandRequest captured;
        final runner = FakeCommandRunner(
          responder: (req) {
            captured = req;
            return const CommandResult(
              exitCode: 0,
              stdout: 'origin/work\n',
              stderr: '',
            );
          },
        );
        final upstream = await GitService(
          runner,
        ).upstreamOf(repo(r'C:\app'), 'work');
        expect(captured.arguments, [
          '-C',
          r'C:\app',
          'for-each-ref',
          '--format=%(upstream:short)',
          'refs/heads/work',
        ]);
        expect(upstream, 'origin/work');
      },
    );

    test('upstreamOf is null for a branch that has never been pushed', () {
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 0, stdout: '\n', stderr: ''),
      );
      expect(
        GitService(runner).upstreamOf(repo(r'C:\app'), 'work'),
        completion(isNull),
      );
    });
  });

  group('ignoredPaths', () {
    test('one process asks about the whole list', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (request) {
          captured = request;
          return const CommandResult(
            exitCode: 0,
            stdout: '.dart_tool\nmacos/Vendor\n',
            stderr: '',
          );
        },
      );
      final ignored = await GitService(runner).ignoredPaths(repo(r'C:\app'), [
        '.dart_tool',
        'macos/Vendor',
        'lib',
      ]);
      expect(captured.arguments, [
        '-C',
        r'C:\app',
        'check-ignore',
        '--',
        '.dart_tool',
        'macos/Vendor',
        'lib',
      ]);
      expect(ignored, {'.dart_tool', 'macos/Vendor'});
      expect(runner.requests, hasLength(1));
    });

    test('no --no-index, so a tracked path reads as not ignored', () async {
      // The default consults the index on purpose: a pattern may match a path
      // that is nonetheless tracked, and copying that over a fresh worktree
      // would replace the new branch's version of it.
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (request) {
          captured = request;
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );
      final ignored = await GitService(
        runner,
      ).ignoredPaths(repo(r'C:\app'), ['lib']);
      expect(captured.arguments, isNot(contains('--no-index')));
      expect(ignored, isEmpty, reason: 'exit 1 means none matched');
    });

    test('an empty list asks git nothing at all', () async {
      final runner = FakeCommandRunner();
      expect(
        await GitService(runner).ignoredPaths(repo(r'C:\app'), const []),
        isEmpty,
      );
      expect(runner.requests, isEmpty);
    });

    test('git refusing the question is null, never an empty set', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 128,
          stdout: '',
          stderr: 'fatal: not a git repository',
        ),
      );
      expect(
        await GitService(runner).ignoredPaths(repo(r'C:\app'), ['.dart_tool']),
        isNull,
      );
    });

    test('an environment that cannot run git is null', () async {
      final runner = FakeCommandRunner(throwError: CommandException('down'));
      expect(
        await GitService(runner).ignoredPaths(repo(r'C:\app'), ['.dart_tool']),
        isNull,
      );
    });
  });

  group('diffUntracked', () {
    test('asks --no-index against the null device', () async {
      late CommandRequest captured;
      final runner = FakeCommandRunner(
        responder: (req) {
          captured = req;
          return const CommandResult(exitCode: 1, stdout: '', stderr: '');
        },
      );
      await GitService(runner).diffUntracked(repo(r'C:\src\app'), 'new.txt');
      expect(captured.arguments, [
        '-C',
        r'C:\src\app',
        'diff',
        '--no-index',
        '--',
        '/dev/null',
        'new.txt',
      ]);
    });

    test('exit 1 is the answer, not a failure', () async {
      // Measured on Windows and WSL git alike: --no-index exits 1 whenever the
      // two sides differ, which for an untracked file is always.
      const patch =
          'diff --git a/new.txt b/new.txt\n'
          'new file mode 100644\n'
          '--- /dev/null\n'
          '+++ b/new.txt\n'
          '@@ -0,0 +1,1 @@\n'
          '+hello\n';
      final runner = FakeCommandRunner(
        responder: (_) =>
            const CommandResult(exitCode: 1, stdout: patch, stderr: ''),
      );
      expect(
        await GitService(runner).diffUntracked(repo(r'C:\src\app'), 'new.txt'),
        patch,
      );
    });

    test('above 1 is git refusing the question', () async {
      final runner = FakeCommandRunner(
        responder: (_) => const CommandResult(
          exitCode: 128,
          stdout: '',
          stderr: 'fatal: not a git repository',
        ),
      );
      expect(
        () => GitService(runner).diffUntracked(repo(r'C:\src\app'), 'new.txt'),
        throwsA(isA<GitException>()),
      );
    });
  });
}
