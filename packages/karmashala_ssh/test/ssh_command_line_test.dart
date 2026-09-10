import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/runner.dart';
import 'package:test/test.dart';

void main() {
  group('posixQuote', () {
    test('wraps a plain word', () {
      expect(posixQuote('claude'), "'claude'");
    });

    test('neutralises shell metacharacters', () {
      for (final hostile in [
        'a;rm -rf /',
        r'$(whoami)',
        '`id`',
        'a && b',
        'a|b',
        r'a\b',
        'a\nb',
        '*',
      ]) {
        final quoted = posixQuote(hostile);
        expect(quoted.startsWith("'"), isTrue);
        expect(quoted.endsWith("'"), isTrue);
        // Everything between the outer quotes is literal: the only way out of a
        // POSIX single-quoted string is a quote, and there is none inside.
        expect(quoted.substring(1, quoted.length - 1), isNot(contains("'")));
      }
    });

    test('splices an embedded single quote back in', () {
      expect(posixQuote("it's"), r"""'it'\''s'""");
    });
  });

  group('buildRemoteCommandLine', () {
    CommandRequest request({
      List<String> arguments = const [],
      String? cwd,
      String executable = 'bash',
    }) => CommandRequest(
      executable: executable,
      arguments: arguments,
      workingDirectory: cwd == null
          ? null
          : EnvironmentPath(environmentId: 'ssh:h1', path: cwd),
    );

    test('quotes the executable and every argument', () {
      expect(
        buildRemoteCommandLine(
          request(arguments: ['-lc', 'command -v claude']),
        ),
        "exec 'bash' '-lc' 'command -v claude'",
      );
    });

    test('prefixes a guarded cd for a working directory', () {
      expect(
        buildRemoteCommandLine(
          request(executable: 'git', arguments: ['status'], cwd: '/srv/repo'),
        ),
        "cd '/srv/repo' && exec 'git' 'status'",
      );
    });

    test('a directory with shell characters cannot break out', () {
      final line = buildRemoteCommandLine(
        request(executable: 'git', arguments: ['status'], cwd: r'/srv/$(id)'),
      );
      expect(line, r"cd '/srv/$(id)' && exec 'git' 'status'");
    });

    test('an argument cannot inject a second command', () {
      final line = buildRemoteCommandLine(
        request(executable: 'echo', arguments: ['; rm -rf /']),
      );
      expect(line, "exec 'echo' '; rm -rf /'");
    });
  });
}
