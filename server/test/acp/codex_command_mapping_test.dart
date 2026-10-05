import 'package:karmashala_host/src/acp/codex/codex_acp_mapping.dart';
import 'package:test/test.dart';

/// A Codex command as the chat shows it: the command the model wrote, not the
/// shell it was wrapped in, and its exit code in words.
void main() {
  Map<String, Object?> run(String command, {int? exitCode, String? output}) =>
      codexToolCall({
        'type': 'commandExecution',
        'id': 'c1',
        'command': command,
        'cwd': r'C:\w',
        'status': 'completed',
        'exitCode': ?exitCode,
        'aggregatedOutput': ?output,
      }, cwd: r'C:\w')!;

  test('the shell wrapper is taken off', () {
    for (final (wrapped, inner) in [
      (
        r'"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" '
            "-Command 'echo hello'",
        'echo hello',
      ),
      (
        r'"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" '
            "-NoProfile -Command 'it''s here'",
        "it's here",
      ),
      ("/bin/bash -lc 'ls -la'", 'ls -la'),
      ('bash -lc "git status"', 'git status'),
      // Joined POSIX-style: a script holding a quote is double-quoted, with
      // its backslashes, quotes, dollars and backticks escaped.
      (
        r'"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" '
            r'''-Command "printf 'One line\\n' > c.txt"''',
        r"printf 'One line\n' > c.txt",
      ),
      (
        r'''/bin/bash -lc "echo 'it' \"\$HOME\" \`id\`"''',
        r'''echo 'it' "$HOME" `id`''',
      ),
      ('git status', 'git status'),
    ]) {
      final call = run(wrapped);
      expect(call['title'], inner, reason: wrapped);
      expect((call['rawInput']! as Map)['command'], inner, reason: wrapped);
    }
  });

  test('a failed command says its exit code in words', () {
    final silent = run('exit 3', exitCode: 3, output: '');
    expect(_text(silent), 'Exit code 3');
    final loud = run('false', exitCode: 1, output: 'boom\n');
    expect(_text(loud), 'Exit code 1\nboom\n');
    final fine = run('true', exitCode: 0, output: 'ok\n');
    expect(_text(fine), 'ok\n');
  });
}

String _text(Map<String, Object?> call) => [
  for (final block in call['content']! as List)
    ((block as Map)['content'] as Map)['text'],
].join();
