import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  CommandResult result(int code, {String out = '', String err = ''}) =>
      CommandResult(exitCode: code, stdout: out, stderr: err);

  group('reading a gitleaks run', () {
    test('0 is clean, 127 is not installed', () {
      expect(secretScanFrom(result(0)), isA<SecretScanClean>());
      expect(secretScanFrom(result(127)), isA<SecretScanUnavailable>());
    });

    test('1 is findings, located and never carrying the secret', () {
      final scan = secretScanFrom(
        result(
          1,
          out:
              '[{"RuleID":"github-pat","StartLine":4,"File":"a/b.txt",'
              '"Commit":"f43e2ea61b81","Secret":"REDACTED"}]',
        ),
      );
      final found = (scan as SecretScanFound).findings.single;
      expect(found.label, 'a/b.txt:4 (github-pat, f43e2ea)');
    });

    test('anything else is a failure, never clean', () {
      final scan = secretScanFrom(result(2, err: 'boom\nbad config'));
      expect((scan as SecretScanFailed).reason, contains('bad config'));
      expect(
        secretScanFrom(result(1, out: 'not json')),
        isA<SecretScanFailed>(),
      );
    });
  });

  /// Against the real tool when it is installed; skipped where it is not.
  group('real gitleaks', () {
    // Each run by name, as the scan runs them: no `sh`, which Windows lacks.
    bool runs(String tool, List<String> args) {
      try {
        return Process.runSync(tool, args).exitCode == 0;
      } on ProcessException {
        return false;
      }
    }

    final hasTools =
        runs('gitleaks', ['version']) && runs('git', ['--version']);
    late Directory tmp;
    late String repo;

    void git(List<String> args) {
      final r = Process.runSync('git', [
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
      if (r.exitCode != 0) fail('git $args: ${r.stderr}');
    }

    void commitToken(String name) {
      // Built at run time so this file carries no token-shaped string.
      final body = List.generate(36, (i) => 'aZ3kQ9xT'[(i * 7 + 3) % 8]).join();
      File(p.join(repo, name)).writeAsStringSync('token = "ghp_$body"\n');
      git(['add', name]);
      git(['commit', '-q', '-m', name]);
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ks-gitleaks');
      repo = p.join(tmp.path, 'repo');
      Directory(repo).createSync();
      git(['init', '-q', '-b', 'main']);
      git(['commit', '-q', '--allow-empty', '-m', 'init']);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    GitService service() => GitService(const LocalCommandRunner());
    EnvironmentPath at() => EnvironmentPath(environmentId: 'local', path: repo);

    test('a token in an outgoing commit is found', () async {
      commitToken('a.txt');
      final scan = await service().scanOutgoingSecrets(at());
      expect(scan, isA<SecretScanFound>());
      expect((scan as SecretScanFound).findings.single.file, 'a.txt');
    }, skip: hasTools ? false : 'needs gitleaks and git on the PATH');

    test('a commit a remote already has is not scanned again', () async {
      commitToken('a.txt');
      git(['update-ref', 'refs/remotes/origin/main', 'HEAD']);
      final scan = await service().scanOutgoingSecrets(at());
      expect(scan, isA<SecretScanClean>());
    }, skip: hasTools ? false : 'needs gitleaks and git on the PATH');
  });
}
