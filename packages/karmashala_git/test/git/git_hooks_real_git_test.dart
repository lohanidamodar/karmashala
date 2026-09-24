import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Against **real git**: a hook is code in `.git`, which an agent can write
/// from inside its own sandbox, so a git this app runs outside that sandbox
/// runs one only for the user's own commit and push.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String repo;
  late GitService service;

  void git(List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      repo,
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
  }

  /// A hook that leaves a marker named after itself.
  void hook(String name) {
    final file = File(p.join(repo, '.git', 'hooks', name))
      ..writeAsStringSync('#!/bin/sh\ntouch "${p.join(tmp.path, name)}"\n');
    Process.runSync('chmod', ['+x', file.path]);
  }

  bool ran(String name) => File(p.join(tmp.path, name)).existsSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-git-hooks');
    repo = p.join(tmp.path, 'repo');
    Directory(repo).createSync();
    git(['init', '-q', '-b', 'main']);
    git(['config', 'user.name', 't']);
    git(['config', 'user.email', 't@t']);
    git(['config', 'commit.gpgsign', 'false']);
    File(p.join(repo, 'a.txt')).writeAsStringSync('a');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'init']);
    service = GitService(const LocalCommandRunner());
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: 'local', path: path);

  test(
    'a merge, a checkout and a worktree the app makes run no hook',
    () async {
      git(['checkout', '-q', '-b', 'side']);
      File(p.join(repo, 'c.txt')).writeAsStringSync('c');
      git(['add', '.']);
      git(['commit', '-q', '-m', 'side']);
      git(['checkout', '-q', 'main']);
      hook('post-checkout');
      hook('post-merge');

      await service.mergeRef(at(repo), 'side');
      await service.createBranch(at(repo), 'next');
      await service.addWorktree(
        at(repo),
        worktreePath: at(p.join(tmp.path, 'wt')),
        branch: 'wt',
      );

      expect(ran('post-merge'), isFalse);
      expect(ran('post-checkout'), isFalse);
    },
    skip: !hasGit || Platform.isWindows ? 'needs POSIX git' : false,
  );

  test("the user's commit still goes through pre-commit", () async {
    hook('pre-commit');
    File(p.join(repo, 'b.txt')).writeAsStringSync('b');
    git(['add', '.']);

    await service.commit(at(repo), 'b');

    expect(ran('pre-commit'), isTrue);
  }, skip: !hasGit || Platform.isWindows ? 'needs POSIX git' : false);

  test('only commit and push keep their hooks', () {
    expect(gitEnvironmentFor(['commit', '-m', 'x']), kGitChildEnvironment);
    expect(gitEnvironmentFor(['push']), kGitChildEnvironment);
    for (final verb in ['merge', 'checkout', 'worktree', 'pull', 'status']) {
      expect(
        gitEnvironmentFor([verb])['GIT_CONFIG_VALUE_0'],
        '/dev/null',
        reason: verb,
      );
    }
  });
}
