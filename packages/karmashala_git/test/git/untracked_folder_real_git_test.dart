import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Against **real git**: a folder git has never seen is listed as its files,
/// not as the one `? dir/` entry git folds it into.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String repo;
  late EnvironmentPath at;

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
    final file = File(p.joinAll([repo, ...name.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-git-untracked');
    repo = p.join(tmp.path, 'repo');
    Directory(repo).createSync();
    at = EnvironmentPath(environmentId: 'local', path: repo);
    git(['init', '-q', '-b', 'main']);
    write('lib/a.txt', 'a\n');
    write('.gitignore', '*.log\n');
    git(['add', '.']);
    git(['commit', '-q', '-m', 'init']);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void addNewFolder() {
    write('lib/a.txt', 'a\nb\n');
    write('lib/feature/one.txt', '1\n');
    write('lib/feature/deep/two.txt', '2\n');
    write('new dir/a b.txt', 'x\n');
    write('new dir/skip.log', 'ignored\n');
  }

  const expected = {
    'lib/a.txt': null,
    'lib/feature/deep/two.txt': 'lib/feature',
    'lib/feature/one.txt': 'lib/feature',
    'new dir/a b.txt': 'new dir',
  };

  Map<String, String?> byPath(List<FileChange> changes) => {
    for (final c in changes) c.path: c.newFolder,
  };

  test('statusWithBranch lists every file in a new nested folder', () async {
    addNewFolder();
    final status = await GitService(
      const LocalCommandRunner(),
    ).statusWithBranch(at);

    expect(byPath(status.changes), expected);
    expect(
      status.changes
          .where((c) => c.newFolder != null)
          .every((c) => c.type == FileChangeType.untracked),
      isTrue,
    );
    expect(changedFileCount(status.changes), 4);
  }, skip: hasGit ? false : 'needs git');

  test('status lists every file in a new nested folder', () async {
    addNewFolder();
    final changes = await GitService(const LocalCommandRunner()).status(at);

    expect(byPath(changes), expected);
  }, skip: hasGit ? false : 'needs git');

  test('a folder past the limit ends in one row counting the rest', () async {
    for (var i = 0; i < 5; i++) {
      write('gen/f$i.txt', '$i\n');
    }
    final status = await GitService(
      const LocalCommandRunner(),
      untrackedFileLimit: 2,
    ).statusWithBranch(at);

    final listed = status.changes.where((c) => c.moreFiles == 0).toList();
    final rest = status.changes.singleWhere((c) => c.moreFiles > 0);
    expect(listed, hasLength(2));
    expect(listed.every((c) => c.newFolder == 'gen'), isTrue);
    expect(rest.path, 'gen/');
    expect(rest.newFolder, 'gen');
    expect(rest.moreFiles, 3);
    expect(changedFileCount(status.changes), 5);
  }, skip: hasGit ? false : 'needs git');
}
