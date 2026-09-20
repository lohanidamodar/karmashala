/// The verbs a Changes panel needs: what each one actually asks git, because
/// the difference between `reset` and `restore --staged`, or between rewinding
/// a file and deleting one, is the whole of their contract.
library;

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

void main() {
  EnvironmentPath repo(String path) =>
      EnvironmentPath(environmentId: 'windows', path: path);

  late FakeCommandRunner runner;
  late GitService git;
  List<String> argsOf(int index) => runner.requests[index].arguments;

  setUp(() {
    runner = FakeCommandRunner();
    git = GitService(runner);
  });

  test('stage adds exactly the paths named, after a --', () async {
    await git.stage(repo(r'C:\src\app'), ['lib/a.dart', 'HEAD']);

    expect(argsOf(0), ['-C', r'C:\src\app', 'add', '--', 'lib/a.dart', 'HEAD']);
  });

  test('unstage restores the index, not the working tree', () async {
    // `restore --staged` rather than `reset`: a repository with no commits has
    // no HEAD to reset against, and that is exactly when someone unstages the
    // first file they ever added.
    await git.unstage(repo('/srv/app'), ['a.txt']);

    expect(argsOf(0), ['-C', '/srv/app', 'restore', '--staged', '--', 'a.txt']);
  });

  test('discard rewinds both the index and the working tree', () async {
    await git.discard(repo('/srv/app'), ['a.txt']);

    expect(argsOf(0), [
      '-C',
      '/srv/app',
      'restore',
      '--staged',
      '--worktree',
      '--',
      'a.txt',
    ]);
  });

  test('deleting an untracked file is its own verb, and says clean', () async {
    await git.deleteUntracked(repo('/srv/app'), ['scratch.txt']);

    expect(argsOf(0), [
      '-C',
      '/srv/app',
      'clean',
      '-f',
      '-d',
      '--',
      'scratch.txt',
    ]);
  });

  test('no paths is no command at all', () async {
    await git.stage(repo('/srv/app'), const []);
    await git.unstage(repo('/srv/app'), const []);
    await git.discard(repo('/srv/app'), const []);
    await git.deleteUntracked(repo('/srv/app'), const []);

    expect(runner.requests, isEmpty);
  });

  test('fetch prunes, and takes a remote when it is given one', () async {
    await git.fetch(repo('/srv/app'));
    await git.fetch(repo('/srv/app'), remote: 'upstream');

    expect(argsOf(0), ['-C', '/srv/app', 'fetch', '--prune']);
    expect(argsOf(1), ['-C', '/srv/app', 'fetch', 'upstream', '--prune']);
  });

  test('pull is fast-forward only unless it is told otherwise', () async {
    await git.pull(repo('/srv/app'));
    await git.pull(repo('/srv/app'), rebase: true);
    await git.pull(repo('/srv/app'), merge: true);

    expect(argsOf(0), ['-C', '/srv/app', 'pull', '--ff-only']);
    expect(argsOf(1), ['-C', '/srv/app', 'pull', '--rebase']);
    expect(argsOf(2), [
      '-C',
      '/srv/app',
      'pull',
      '--no-rebase',
      '--no-edit',
    ], reason: 'a merge pull must not open an editor there is no terminal for');
  });

  test('a refusal is the sentence git gave, not an exit code', () async {
    runner.responder = (_) => const CommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'fatal: Not possible to fast-forward, aborting.\n',
    );

    await expectLater(
      git.pull(repo('/srv/app')),
      throwsA(
        isA<GitException>().having(
          (e) => e.toString(),
          'message',
          contains('Not possible to fast-forward'),
        ),
      ),
    );
  });
}
