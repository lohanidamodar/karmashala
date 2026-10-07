import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';

/// Lines rendered through a VT parser from the real PTY captures in the app's
/// `test/features/agents/fixtures/` — the app's `working_line_fixtures_test`
/// renders the captures themselves.
void main() {
  final now = DateTime.utc(2026, 10, 7, 12);
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!.grid;
  final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!.grid;

  AgentWorkingDetail? readClaude(String line) =>
      claude.workingLine!.readLine(line, now);
  AgentWorkingDetail? readCodex(String line) =>
      codex.workingLine!.readLine(line, now);

  group('Claude Code', () {
    test('word, seconds and tokens', () {
      final detail = readClaude('✻ Sautéing… (2s · ↓ 7 tokens)')!;
      expect(detail.word, 'Sautéing…');
      expect(detail.since, now.subtract(const Duration(seconds: 2)));
      expect(detail.tokens, 7);
    });

    test('a trailing part after the tokens', () {
      final detail = readClaude(
        '· Skedaddling… (3s · ↓ 50 tokens · thinking)',
      )!;
      expect(detail.word, 'Skedaddling…');
      expect(detail.tokens, 50);
    });

    test('the glyph blinked off', () {
      expect(
        readClaude('  Skedaddling… (3s · ↓ 50 tokens · thinking)')?.word,
        'Skedaddling…',
      );
    });

    test('minutes, thousands and the interrupt hint', () {
      final detail = readClaude(
        '✻ Booping… (1m 12s · ↑ 1.2k tokens · esc to interrupt)',
      )!;
      expect(detail.word, 'Booping…');
      expect(
        detail.since,
        now.subtract(const Duration(minutes: 1, seconds: 12)),
      );
      expect(detail.tokens, 1200);
    });

    test('no tokens yet', () {
      final detail = readClaude('✶ Booping… (0s)')!;
      expect(detail.word, 'Booping…');
      expect(detail.tokens, isNull);
      expect(detail.since, now);
    });

    test('lines that are not working lines', () {
      for (final line in [
        // A message row half repainted over the spinner, in the capture.
        '● hello-fg… (4s · ↓ 83 tokens)',
        // Still being drawn.
        '· Skedaddling… (2s · ↓ 25 tokens ·',
        // The footer, which carries the hint but no word.
        '  ⏵⏵ accept edits on (shift+tab to cycle) · esc to interrupt',
        '❯ Try "fix the failing test" (3s)',
        'Reading files (3s · 12 tokens)',
        '',
      ]) {
        expect(readClaude(line), isNull, reason: line);
      }
    });

    test('the lowest working line on the screen is the one read', () {
      final detail = claude.workingLine!.read([
        '✻ Pondering… (9s · ↓ 1 tokens)',
        '',
        '✻ Sautéing… (2s · ↓ 7 tokens)',
        '──────────',
        '❯ ',
        '  ⏸ manual mode on · esc to interrupt',
      ], now);
      expect(detail?.word, 'Sautéing…');
    });
  });

  group('Codex', () {
    test('its word and seconds; it reports no tokens', () {
      final detail = readCodex('• Working (3s • esc to interrupt)')!;
      expect(detail.word, 'Working');
      expect(detail.since, now.subtract(const Duration(seconds: 3)));
      expect(detail.tokens, isNull);
    });

    test('a header with parentheses of its own', () {
      final detail = readCodex(
        '• Starting MCP servers (0/2): agent-browser, codex_apps (0s • esc to '
        'interrupt)',
      )!;
      expect(
        detail.word,
        'Starting MCP servers (0/2): agent-browser, codex_apps',
      );
      expect(detail.since, now);
    });

    test('minutes', () {
      expect(
        readCodex('• Working (1m 02s • esc to interrupt)')!.since,
        now.subtract(const Duration(minutes: 1, seconds: 2)),
      );
    });

    test('lines that are not working lines', () {
      for (final line in [
        '• Working (3s)',
        '• Ran git status (3s • esc to interrupt',
        '› Explain this codebase',
        '  gpt-5.1-codex medium · 100% left · ~/scratch',
      ]) {
        expect(readCodex(line), isNull, reason: line);
      }
    });
  });

  group('what the status report carries', () {
    test('the same at the grain a reader sees', () {
      final a = AgentWorkingDetail(word: 'Booping…', since: now, tokens: 1210);
      expect(
        a.sameAs(
          AgentWorkingDetail(
            word: 'Booping…',
            since: now.add(const Duration(seconds: 1)),
            tokens: 1290,
          ),
        ),
        isTrue,
      );
      expect(
        a.sameAs(
          AgentWorkingDetail(word: 'Booping…', since: now, tokens: 1300),
        ),
        isFalse,
      );
      expect(
        a.sameAs(
          AgentWorkingDetail(
            word: 'Booping…',
            since: now.add(const Duration(seconds: 3)),
            tokens: 1210,
          ),
        ),
        isFalse,
      );
      expect(
        a.sameAs(
          AgentWorkingDetail(word: 'Pondering…', since: now, tokens: 1210),
        ),
        isFalse,
      );
      expect(
        const AgentWorkingDetail(
          tokens: 7,
        ).sameAs(const AgentWorkingDetail(tokens: 8)),
        isFalse,
      );
    });

    test('round-trips, and reads nothing from nothing', () {
      final detail = AgentWorkingDetail(word: 'Working', since: now, tokens: 9);
      final back = AgentWorkingDetail.fromJson(detail.toJson())!;
      expect(back.word, 'Working');
      expect(back.since, now);
      expect(back.tokens, 9);
      expect(AgentWorkingDetail.fromJson(const <String, Object?>{}), isNull);
      expect(AgentWorkingDetail.fromJson('Working'), isNull);
    });

    test('an agent whose line nobody has read declares no rule', () {
      expect(
        AgentRegistry.builtIn.byId(AgentIds.antigravity)!.grid.workingLine,
        isNull,
      );
    });
  });
}
