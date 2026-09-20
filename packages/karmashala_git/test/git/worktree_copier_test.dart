import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_command_runner.dart';
import '../support/fixtures.dart';
import '../support/temp_directory.dart';

void main() {
  group('the copier is chosen by the environment, never by the platform', () {
    final runner = FakeCommandRunner();

    test('the two kinds that are this process\'s own filesystem', () {
      expect(
        worktreeCopierFor(windowsEnv(), runner).copier,
        isA<HostWorktreeCopier>(),
      );
      expect(
        worktreeCopierFor(posixEnv(), runner).copier,
        isA<HostWorktreeCopier>(),
      );
    });

    test('WSL runs cp inside the distribution', () {
      expect(
        worktreeCopierFor(wslEnv(), runner).copier,
        isA<ShellWorktreeCopier>(),
      );
    });

    test('SSH runs cp on the far host — nothing local names that disk', () {
      expect(
        worktreeCopierFor(sshEnvFixture(), runner).copier,
        isA<ShellWorktreeCopier>(),
      );
    });

    test('paths are written in each environment\'s own separator', () {
      expect(worktreeCopierFor(windowsEnv(), runner).context, p.windows);
      expect(worktreeCopierFor(wslEnv(), runner).context, p.posix);
      expect(worktreeCopierFor(sshEnvFixture(), runner).context, p.posix);
    });
  });

  group('the host copier, against a real disk', () {
    late Directory root;
    late String source;
    late String destination;

    setUp(() {
      root = Directory.systemTemp.createTempSync('wt-copy');
      source = p.join(root.path, 'checkout');
      destination = p.join(root.path, 'worktree');
      Directory(source).createSync();
      Directory(destination).createSync();
    });
    tearDown(() => removeTempDirectory(root));

    Future<WorktreeCopyVerdict> copy(String path) =>
        const HostWorktreeCopier().copy(
          path: path,
          source: p.join(source, path),
          destination: p.join(destination, path),
        );

    test('copies a directory and counts what it wrote', () async {
      Directory(
        p.join(source, '.dart_tool', 'nested'),
      ).createSync(recursive: true);
      File(
        p.join(source, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync('{}');
      File(
        p.join(source, '.dart_tool', 'nested', 'a.txt'),
      ).writeAsStringSync('a');

      final verdict = await copy('.dart_tool');
      expect(verdict.result, WorktreeCopyResult.copied);
      expect(verdict.reason, contains('2 files'));
      expect(
        File(
          p.join(destination, '.dart_tool', 'nested', 'a.txt'),
        ).readAsStringSync(),
        'a',
      );
    });

    test('copies a single file, and makes the folder it goes in', () async {
      Directory(p.join(source, 'android')).createSync();
      File(p.join(source, 'android', 'key.properties')).writeAsStringSync('k');

      final verdict = await copy('android/key.properties');
      expect(verdict.result, WorktreeCopyResult.copied);
      expect(
        File(
          p.join(destination, 'android', 'key.properties'),
        ).readAsStringSync(),
        'k',
      );
    });

    test('nothing at the source is an answer, not a failure', () async {
      final verdict = await copy('macos/Vendor');
      expect(verdict.result, WorktreeCopyResult.nothingAtSource);
      expect(verdict.reason, contains('nothing to copy'));
    });

    test('an occupied destination is refused, never merged into', () async {
      Directory(p.join(source, 'build')).createSync();
      File(p.join(source, 'build', 'fresh.txt')).writeAsStringSync('new');
      Directory(p.join(destination, 'build')).createSync();
      File(p.join(destination, 'build', 'theirs.txt')).writeAsStringSync('old');

      final verdict = await copy('build');
      expect(verdict.result, WorktreeCopyResult.refusedOccupied);
      expect(verdict.reason, contains('merge'));
      expect(
        File(p.join(destination, 'build', 'fresh.txt')).existsSync(),
        isFalse,
        reason: 'a refusal writes nothing at all',
      );
    });
  });

  group('the shell copier, for a repository this process cannot open', () {
    late FakeCommandRunner runner;
    late ShellWorktreeCopier copier;

    /// Answers `test -e <path>` for the paths in [present], and lets
    /// everything else succeed.
    void filesystem({required Set<String> present}) {
      runner.responder = (request) {
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

    setUp(() {
      runner = FakeCommandRunner(environmentId: 'wsl:Ubuntu');
      copier = ShellWorktreeCopier(runner);
    });

    Future<WorktreeCopyVerdict> copy(String path) => copier.copy(
      path: path,
      source: '/home/me/app/$path',
      destination: '/home/me/.karmashala-worktrees/app-s1/$path',
    );

    test('copies with cp -a, in the repository\'s own environment', () async {
      filesystem(present: {'/home/me/app/.dart_tool'});

      final verdict = await copy('.dart_tool');
      expect(verdict.result, WorktreeCopyResult.copied);
      expect(runner.requests.map((r) => [r.executable, ...r.arguments]), [
        ['test', '-e', '/home/me/app/.dart_tool'],
        ['test', '-e', '/home/me/.karmashala-worktrees/app-s1/.dart_tool'],
        [
          'cp',
          '-a',
          '/home/me/app/.dart_tool',
          '/home/me/.karmashala-worktrees/app-s1/.dart_tool',
        ],
      ]);
    });

    test('a nested path gets its folder made first', () async {
      filesystem(present: {'/home/me/app/macos/Vendor'});

      await copy('macos/Vendor');
      expect(runner.requests.map((r) => [r.executable, ...r.arguments]), [
        ['test', '-e', '/home/me/app/macos/Vendor'],
        ['test', '-e', '/home/me/.karmashala-worktrees/app-s1/macos/Vendor'],
        ['mkdir', '-p', '/home/me/.karmashala-worktrees/app-s1/macos'],
        [
          'cp',
          '-a',
          '/home/me/app/macos/Vendor',
          '/home/me/.karmashala-worktrees/app-s1/macos/Vendor',
        ],
      ]);
    });

    test('never asks for a link — not ln, not cp -s, not mklink', () async {
      filesystem(present: {'/home/me/app/node_modules'});
      await copy('node_modules');
      for (final request in runner.requests) {
        expect(request.executable, isNot(anyOf('ln', 'mklink')));
        expect(request.arguments, isNot(contains('-s')));
        expect(request.arguments, isNot(contains('--symbolic-link')));
      }
    });

    test('nothing at the source stops before cp runs', () async {
      filesystem(present: const {});
      final verdict = await copy('.dart_tool');
      expect(verdict.result, WorktreeCopyResult.nothingAtSource);
      expect(runner.requests.map((r) => r.executable), ['test']);
    });

    test('an occupied destination is refused before cp runs', () async {
      filesystem(
        present: {
          '/home/me/app/build',
          '/home/me/.karmashala-worktrees/app-s1/build',
        },
      );
      final verdict = await copy('build');
      expect(verdict.result, WorktreeCopyResult.refusedOccupied);
      expect(verdict.reason, contains('merges'));
      expect(runner.requests.map((r) => r.executable), ['test', 'test']);
    });

    test(
      'a probe that could not answer is unknown, never "not there"',
      () async {
        // 126/127 is the shell failing to run `test`, not `test` saying no.
        runner.responder = (_) =>
            const CommandResult(exitCode: 127, stdout: '', stderr: 'not found');
        final verdict = await copy('.dart_tool');
        expect(verdict.result, WorktreeCopyResult.unknown);
        expect(verdict.reason, contains('could not be taken'));
      },
    );

    test('an environment that will not run anything is unknown', () async {
      runner.throwError = CommandException('WSL is not running');
      final verdict = await copy('.dart_tool');
      expect(verdict.result, WorktreeCopyResult.unknown);
    });

    test('cp\'s own words are carried into the failure', () async {
      runner.responder = (request) => switch (request.executable) {
        'test' => CommandResult(
          exitCode: request.arguments.last.contains('worktrees') ? 1 : 0,
          stdout: '',
          stderr: '',
        ),
        _ => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: "cp: cannot stat '…': Permission denied",
        ),
      };
      final verdict = await copy('.dart_tool');
      expect(verdict.result, WorktreeCopyResult.failed);
      expect(verdict.reason, contains('Permission denied'));
    });
  });
}
