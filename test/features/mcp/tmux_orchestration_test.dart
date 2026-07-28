import 'package:chitragupta/src/features/mcp/tmux_orchestration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildTmuxScript', () {
    test('creates a session then a window per entry and attaches', () {
      final script = buildTmuxScript('appwrite', [
        const TmuxWindow(
          label: 'analytics',
          cwd: '/home/x/appwrite',
          command: '/home/x/.local/bin/claude --resume A',
        ),
        const TmuxWindow(
          label: 'usage',
          cwd: '/home/x/appwrite',
          command: '/home/x/.local/bin/claude --resume B',
        ),
      ]);

      final lines = script.trim().split('\n');
      expect(lines.first, '#!/usr/bin/env bash');
      expect(script, contains("tmux kill-session -t 'appwrite'"));
      expect(
        script,
        contains(
          "tmux new-session -d -s 'appwrite' -n 'analytics' "
          "-c '/home/x/appwrite' '/home/x/.local/bin/claude --resume A'",
        ),
      );
      expect(
        script,
        contains(
          "tmux new-window -t 'appwrite' -n 'usage' "
          "-c '/home/x/appwrite' '/home/x/.local/bin/claude --resume B'",
        ),
      );
      expect(script.trim(), endsWith("tmux attach -t 'appwrite'"));
      // Exactly one new-session, one new-window.
      expect('new-session'.allMatches(script).length, 1);
      expect('new-window'.allMatches(script).length, 1);
    });

    test('escapes embedded single quotes', () {
      final script = buildTmuxScript("it's", [
        const TmuxWindow(label: "a'b", cwd: '/tmp', command: "echo 'hi'"),
      ]);
      expect(script, contains(r"'it'\''s'"));
      expect(script, contains(r"'a'\''b'"));
      expect(script, contains(r"'echo '\''hi'\'''"));
    });

    test('returns empty for no windows', () {
      expect(buildTmuxScript('x', const []), '');
    });
  });

  group('tmuxSafeName', () {
    test('lowercases and collapses non-alphanumerics to dashes', () {
      expect(tmuxSafeName('Appwrite AI · workdir'), 'appwrite-ai-workdir');
      expect(tmuxSafeName('  --foo.bar--  '), 'foo-bar');
      expect(tmuxSafeName('!!!', fallback: 'session'), 'session');
    });
  });
}
