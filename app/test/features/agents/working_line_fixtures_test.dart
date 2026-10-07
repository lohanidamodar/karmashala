import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:xterm2/xterm.dart';

/// The working line read off real PTY captures, laid out by a VT parser first:
/// both agents place their words with cursor moves, not spaces.
AgentWorkingDetail? workingAt(String fixture, double fraction, DateTime now) {
  final bytes = File(
    'test/features/agents/fixtures/$fixture.raw',
  ).readAsStringSync();
  final terminal = Terminal(maxLines: 10000)..resize(120, 30);
  terminal.write(bytes.substring(0, (bytes.length * fraction).round()));
  final grid = AgentRegistry.builtIn
      .byId(fixture.startsWith('codex') ? AgentIds.codex : AgentIds.claudeCode)!
      .grid;
  return grid.workingLine!.read(
    terminalTailLines(terminal, lines: grid.scanLines),
    now,
  );
}

void main() {
  final now = DateTime.utc(2026, 10, 7, 12);

  test('Claude Code mid-turn: its word, seconds and tokens', () {
    final detail = workingAt('claude-code-approval-prompt', 0.6275, now)!;
    expect(detail.word, 'Sautéing…');
    expect(detail.since, now.subtract(const Duration(seconds: 2)));
    expect(detail.tokens, 9);
  });

  test('Claude Code thinking: the part after the tokens is left out', () {
    final detail = workingAt('claude-code-permission-modal', 0.7475, now)!;
    expect(detail.word, 'Skedaddling…');
    expect(detail.since, now.subtract(const Duration(seconds: 3)));
    expect(detail.tokens, 50);
  });

  test('Codex mid-turn: its word and seconds', () {
    final detail = workingAt('codex-tui', 0.615, now)!;
    expect(detail.word, 'Working');
    expect(detail.since, now.subtract(const Duration(seconds: 3)));
    expect(detail.tokens, isNull);
  });

  test('screens with no working line read nothing', () {
    // The trust question before any turn, and a message row painted over
    // the spinner's row as the turn ends.
    expect(workingAt('claude-code-trust-prompt', 1.0, now), isNull);
    expect(workingAt('claude-code-approval-prompt', 0.87, now), isNull);
    expect(workingAt('codex-approval-prompt', 0.019, now), isNull);
  });
}
