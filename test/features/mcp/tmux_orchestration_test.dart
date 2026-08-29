import 'package:chitragupta/src/features/mcp/tmux_orchestration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildTmuxScript', () {
    test('is non-destructive: appends to an existing session, else creates', () {
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

      expect(script.split('\n').first, '#!/usr/bin/env bash');
      // Never kills an existing session.
      expect(script, isNot(contains('kill-session')));
      // Branches on whether the session already exists.
      expect(script, contains("if tmux has-session -t 'appwrite' 2>/dev/null"));
      // Existing branch: append windows with -d (no focus steal).
      expect(
        script,
        contains(
          "tmux new-window -d -t 'appwrite' -n 'analytics' "
          "-c '/home/x/appwrite' '/home/x/.local/bin/claude --resume A'",
        ),
      );
      // New branch: first is a new-session, rest are new-window.
      expect(
        script,
        contains(
          "tmux new-session -d -s 'appwrite' -n 'analytics' "
          "-c '/home/x/appwrite' '/home/x/.local/bin/claude --resume A'",
        ),
      );
      expect(script.trim(), endsWith("tmux attach -t 'appwrite'"));
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
