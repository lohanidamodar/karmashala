import 'dart:io';

import 'package:karmashala_git/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Against **real git**: a file picked out of a diff is a patch `git apply`
/// accepts, whatever kind of file or name it has.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String repo;

  ProcessResult run(List<String> args) => Process.runSync('git', [
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

  void git(List<String> args) {
    final result = run(args);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
  }

  /// The working tree's diff against HEAD, as the checkpoint code asks for it.
  String diff() => run(['diff', '--no-color', '--binary', 'HEAD']).stdout
      as String;

  /// Whether `git apply -R --check` takes [patch] — the restore's own call.
  String? applyRefusal(String patch) {
    final file = File(p.join(tmp.path, 'pick.patch'))..writeAsStringSync(patch);
    final result = run(['apply', '-R', '--check', file.path]);
    return result.exitCode == 0 ? null : result.stderr as String;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-hunk-real');
    repo = p.join(tmp.path, 'repo');
    Directory(repo).createSync();
    git(['init', '-q']);
    git(['config', 'core.autocrlf', 'false']);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a git file a moment longer; the OS cleans temp.
    }
  });

  test('a binary file picked on its own still applies', () {
    File(p.join(repo, 'logo.bin')).writeAsBytesSync([0, 1, 2, 3, 0, 255]);
    File(p.join(repo, 'note.txt')).writeAsStringSync('one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'init']);
    File(p.join(repo, 'logo.bin')).writeAsBytesSync([0, 9, 9, 9, 0, 255, 7]);
    File(p.join(repo, 'note.txt')).writeAsStringSync('two\n');

    final patch = patchForFiles(diff(), ['logo.bin']);
    expect(patch, contains('GIT binary patch'));
    expect(patch, isNot(contains('note.txt')));
    expect(applyRefusal(patch), isNull);
  }, skip: hasGit ? false : 'git is not on PATH');

  test('a file whose name git quotes is found by its own name', () {
    File(p.join(repo, 'café.txt')).writeAsStringSync('one\n');
    File(p.join(repo, 'plain.txt')).writeAsStringSync('one\n');
    git(['add', '-A']);
    git(['commit', '-q', '-m', 'init']);
    File(p.join(repo, 'café.txt')).writeAsStringSync('two\n');
    File(p.join(repo, 'plain.txt')).writeAsStringSync('two\n');

    final files = splitUnifiedDiff(diff());
    expect(files.map((f) => f.path), containsAll(['café.txt', 'plain.txt']));
    final patch = patchForFiles(diff(), ['café.txt']);
    expect(patch, isNotEmpty);
    expect(patch, isNot(contains('plain.txt')));
    expect(applyRefusal(patch), isNull);
  }, skip: hasGit ? false : 'git is not on PATH');
}
