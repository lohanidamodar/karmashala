import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Against **real git**: a branch's line count is its own work, however far
/// the base has moved since it left.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String repo;

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
    File(p.join(repo, name)).writeAsStringSync(text);
    git(['add', name]);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-git-diff-base');
    repo = p.join(tmp.path, 'repo');
    Directory(repo).createSync();
    git(['init', '-q', '-b', 'main']);
    write('a.txt', 'a\n');
    git(['commit', '-q', '-m', 'init']);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    "commits the base gained after the branch left are not the branch's",
    () async {
      git(['checkout', '-q', '-b', 'side']);
      write('mine.txt', 'one\n');
      git(['commit', '-q', '-m', 'mine']);
      git(['checkout', '-q', 'main']);
      write('theirs.txt', '1\n2\n3\n4\n5\n');
      git(['commit', '-q', '-m', 'theirs']);
      git(['checkout', '-q', 'side']);
      // Uncommitted work still counts.
      File(p.join(repo, 'a.txt')).writeAsStringSync('a\nb\n');

      final stat = await GitService(const LocalCommandRunner()).diffStat(
        EnvironmentPath(environmentId: 'local', path: repo),
        base: 'main',
      );

      expect(stat?.added, 2);
      expect(stat?.removed, 0);
      expect(stat?.files, 2);
    },
    skip: hasGit ? false : 'needs git',
  );
}
