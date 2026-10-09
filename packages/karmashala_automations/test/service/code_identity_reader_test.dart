@Timeout.factor(4)
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/check_runner.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

/// Against **real git**: which code a checkout holds, and a recorded one held
/// against it after a commit, an edit, a new file or a branch switch.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;
  final skip = hasGit ? false : 'needs git';

  late Directory tmp;
  late String repo;
  late EnvironmentPath at;
  late CodeIdentityReader reader;

  void git(List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      repo,
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
  }

  void write(String name, String text) {
    final file = File('$repo/$name');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-code-identity');
    repo = '${tmp.path}${Platform.pathSeparator}repo';
    Directory(repo).createSync();
    at = EnvironmentPath(environmentId: 'local', path: repo);
    git(['init', '-q', '-b', 'main']);
    write('lib/a.txt', 'a\n');
    write('lib/b.txt', 'b\n');
    write('.gitignore', '*.log\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'init']);
    reader = CodeIdentityReader(
      <T>(
        EnvironmentPath where,
        Future<T> Function(GitService git, EnvironmentPath at) question,
      ) => question(GitService(const LocalCommandRunner()), where),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('records the commit, the checkout and the uncommitted files', () async {
    write('lib/a.txt', 'a2\n');
    write('notes.txt', 'new\n');
    final identity = (await reader.read(at))!;

    expect(identity.environmentId, 'local');
    expect(identity.path, repo);
    expect(identity.head, hasLength(40));
    expect(identity.dirtyCount, 2);
    expect(identity.dirty!.keys, unorderedEquals(['lib/a.txt', 'notes.txt']));
    expect(identity.changedDuringRun, isFalse);
  }, skip: skip);

  test('the same code reads fresh', () async {
    write('lib/a.txt', 'a2\n');
    final recorded = await reader.read(at);
    expect(
      (await reader.freshnessOf(recorded)).state,
      CodeFreshnessState.fresh,
    );
  }, skip: skip);

  test('an edit to a tracked file makes it stale, counted', () async {
    final recorded = await reader.read(at);
    write('lib/a.txt', 'changed\n');
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.filesChanged, 1);
    expect(freshness.label, 'stale (1 file changed since)');
  }, skip: skip);

  test('an edit inside a file that was already dirty is caught', () async {
    write('lib/a.txt', 'first edit\n');
    final recorded = await reader.read(at);
    write('lib/a.txt', 'second edit\n');
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.filesChanged, 1);
  }, skip: skip);

  test(
    'a new untracked file makes it stale; an ignored one does not',
    () async {
      final recorded = await reader.read(at);
      write('build.log', 'ignored\n');
      expect((await reader.freshnessOf(recorded)).isFresh, isTrue);
      write('lib/new.txt', 'new\n');
      final freshness = await reader.freshnessOf(recorded);
      expect(freshness.state, CodeFreshnessState.stale);
      expect(freshness.filesChanged, 1);
    },
    skip: skip,
  );

  test('a commit makes it stale, counting files, not commits', () async {
    final recorded = await reader.read(at);
    write('lib/a.txt', 'a2\n');
    write('lib/b.txt', 'b2\n');
    git(['commit', '-q', '-am', 'two files']);
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.filesChanged, 2);
    expect(freshness.reason, contains('another commit'));
  }, skip: skip);

  test('committing exactly the edits that were checked is still the same '
      'files, but another commit', () async {
    write('lib/a.txt', 'a2\n');
    final recorded = await reader.read(at);
    git(['commit', '-q', '-am', 'the checked edit']);
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.filesChanged, 0);
  }, skip: skip);

  test('switching branches makes it stale', () async {
    git(['checkout', '-q', '-b', 'other']);
    write('lib/b.txt', 'other\n');
    git(['commit', '-q', '-am', 'other']);
    git(['checkout', '-q', 'main']);
    final recorded = await reader.read(at);
    git(['checkout', '-q', 'other']);
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.filesChanged, 1);
  }, skip: skip);

  test('a deleted file counts as a change', () async {
    final recorded = await reader.read(at);
    File('$repo/lib/b.txt').deleteSync();
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.filesChanged, 1);
  }, skip: skip);

  test('a run whose code moved under it is stale', () async {
    final recorded = (await reader.read(at))!.copyWith(changedDuringRun: true);
    final freshness = await reader.freshnessOf(recorded);
    expect(freshness.state, CodeFreshnessState.stale);
    expect(freshness.reason, contains('while this ran'));
  }, skip: skip);

  test('a checkout that cannot be read is unknown, never a pass', () async {
    final recorded = await reader.read(at);
    tmp.deleteSync(recursive: true);
    tmp.createSync();
    expect(
      (await reader.freshnessOf(recorded)).state,
      CodeFreshnessState.unknown,
    );
  }, skip: skip);

  test('an old result with nothing recorded is unknown', () async {
    expect(await reader.freshnessOf(null), CodeFreshness.notRecorded);
  });

  test('a folder that is not a checkout has no identity', () async {
    final plain = Directory('${tmp.path}/plain')..createSync();
    expect(
      await reader.read(
        EnvironmentPath(environmentId: 'local', path: plain.path),
      ),
      isNull,
    );
  }, skip: skip);

  test('too many uncommitted files to hash is unknown, never fresh', () async {
    final small = CodeIdentityReader(
      <T>(
        EnvironmentPath where,
        Future<T> Function(GitService git, EnvironmentPath at) question,
      ) => question(GitService(const LocalCommandRunner()), where),
      maxDirtyFiles: 1,
    );
    write('x.txt', 'x\n');
    write('y.txt', 'y\n');
    final recorded = (await small.read(at))!;
    expect(recorded.dirty, isNull);
    expect(recorded.dirtyCount, 2);
    expect(
      (await small.freshnessOf(recorded)).state,
      CodeFreshnessState.unknown,
    );
  }, skip: skip);
}
