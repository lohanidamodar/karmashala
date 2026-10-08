import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Against **real git**: a pull request from a fork is checked out from the
/// base repository's `refs/pull/<n>/head`, the way GitHub serves it, into a
/// branch of its own — never from a same-named branch of the base.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String base;
  late String fork;
  late String checkout;

  String git(String dir, List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      dir,
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  String commit(String dir, String name, String text) {
    File(p.join(dir, name)).writeAsStringSync(text);
    git(dir, ['add', name]);
    git(dir, ['commit', '-q', '-m', name]);
    return git(dir, ['rev-parse', 'HEAD']);
  }

  /// What GitHub does when a fork opens pull request [number]: the base
  /// repository gets the fork's head as `refs/pull/<number>/head`.
  void openPullRequest(int number) =>
      git(fork, ['push', '-q', '--force', base, 'HEAD:refs/pull/$number/head']);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-pull-ref');
    base = p.join(tmp.path, 'base.git');
    fork = p.join(tmp.path, 'fork');
    checkout = p.join(tmp.path, 'shop');
    Directory(base).createSync();
    git(base, ['init', '-q', '--bare', '-b', 'main']);
    Directory(fork).createSync();
    git(fork, ['init', '-q', '-b', 'main']);
    commit(fork, 'a.txt', 'a\n');
    git(fork, ['push', '-q', base, 'main']);
    git(tmp.path, ['clone', '-q', base, checkout]);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  final env = Platform.isWindows ? windowsEnv() : posixEnv();

  WorktreeService service() => WorktreeService(
    runnerFactory: const CommandRunnerFactory(),
    environmentOf: (_) => env,
  );

  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: env.id, path: path);

  test('a fork\'s branch, named like the base\'s own, is fetched from the pull '
      'ref into pr/<n>-<branch>', () async {
    // The fork's work is on its `main`, which the base also has.
    final forkHead = commit(fork, 'fix.txt', 'the fix\n');
    openPullRequest(7);
    final baseMain = git(checkout, ['rev-parse', 'origin/main']);
    expect(forkHead, isNot(baseMain));

    final tracker = WorktreeCreationTracker(repo: at(checkout));
    final created = await service().create(
      repo: at(checkout),
      worktreeName: 'pr7',
      branch: 'pr/7-main',
      existingBranch: true,
      fetchRef: const WorktreeRefFetch(
        ref: 'refs/pull/7/head',
        repository: 'someone/shop',
      ),
      tracker: tracker,
    );

    final worktree = created.worktree.path.path;
    expect(created.worktree.branch, 'pr/7-main');
    expect(git(worktree, ['rev-parse', 'HEAD']), forkHead);
    expect(File(p.join(worktree, 'fix.txt')).existsSync(), isTrue);
    final fetch = tracker.record.stage(WorktreeStage.fetch);
    expect(fetch.state, WorktreeStageState.done);
    expect(fetch.detail, contains('refs/pull/7/head from origin'));
    // The base's own main is untouched.
    expect(git(checkout, ['rev-parse', 'main']), baseMain);
  }, skip: hasGit ? false : 'needs git');

  test(
    'a force-push to the pull request is followed on the next checkout',
    () async {
      commit(fork, 'fix.txt', 'first\n');
      openPullRequest(7);
      final first = await service().create(
        repo: at(checkout),
        worktreeName: 'pr7a',
        branch: 'pr/7-main',
        existingBranch: true,
        fetchRef: const WorktreeRefFetch(ref: 'refs/pull/7/head'),
      );
      await service().remove(at(checkout), first.worktree.path, force: true);

      git(fork, ['reset', '-q', '--hard', 'HEAD~1']);
      final rewritten = commit(fork, 'fix.txt', 'rewritten\n');
      openPullRequest(7);
      final second = await service().create(
        repo: at(checkout),
        worktreeName: 'pr7b',
        branch: 'pr/7-main',
        existingBranch: true,
        fetchRef: const WorktreeRefFetch(ref: 'refs/pull/7/head'),
      );

      expect(git(second.worktree.path.path, ['rev-parse', 'HEAD']), rewritten);
    },
    skip: hasGit ? false : 'needs git',
  );

  test('a pull request that is not there is refused in git\'s words', () async {
    final tracker = WorktreeCreationTracker(repo: at(checkout));
    await expectLater(
      service().create(
        repo: at(checkout),
        worktreeName: 'pr9',
        branch: 'pr/9-x',
        existingBranch: true,
        fetchRef: const WorktreeRefFetch(ref: 'refs/pull/9/head'),
        tracker: tracker,
      ),
      throwsA(isA<GitException>()),
    );
    expect(
      tracker.record.stage(WorktreeStage.fetch).state,
      WorktreeStageState.warning,
    );
  }, skip: hasGit ? false : 'needs git');

  group('remoteNaming', () {
    test('picks the remote whose URL names the repository', () {
      expect(
        remoteNaming({
          'origin': 'git@github.com:me/shop.git',
          'upstream': 'https://github.com/Someone/Shop.git',
        }, 'someone/shop'),
        'upstream',
      );
    });

    test('falls back to origin, then to the only remote', () {
      expect(
        remoteNaming({'origin': '/srv/base.git'}, 'someone/shop'),
        'origin',
      );
      expect(remoteNaming({'mine': '/srv/base.git'}, null), 'mine');
      expect(remoteNaming({'a': '/x', 'b': '/y'}, 'someone/shop'), isNull);
      expect(remoteNaming(const {}, 'someone/shop'), isNull);
    });
  });
}
