import 'dart:io';

import 'package:chitragupta/src/features/agents/data/terminal_grid_status_source.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_grid_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Renders [fraction] of a captured PTY stream through a real VT parser and
/// classifies the bottom of the resulting screen.
///
/// The stream is deliberately fed through xterm rather than pattern-matched
/// directly: both agents position words with cursor-movement escapes rather than
/// spaces, so `esc to interrupt` does not exist as a substring anywhere in the
/// bytes. It only exists once something has placed those words in columns.
AgentStatusReport? classify(String fixture, double fraction) {
  final bytes = File(
    'test/features/agents/fixtures/$fixture.raw',
  ).readAsStringSync();
  final terminal = Terminal(maxLines: 10000)..resize(120, 30);
  terminal.write(bytes.substring(0, (bytes.length * fraction).round()));
  final descriptor = AgentRegistry.builtIn.byId(
    fixture.startsWith('codex') ? AgentIds.codex : AgentIds.claudeCode,
  )!;
  return const TerminalGridStatusSource().read(
    descriptor,
    terminalTailLines(terminal, lines: descriptor.grid.scanLines),
    DateTime.utc(2026, 8, 30),
    sessionId: 'session',
  );
}

void main() {
  group('the raw byte stream is not classifiable', () {
    test('the marker only exists once a VT parser has laid out the screen', () {
      final bytes = File(
        'test/features/agents/fixtures/claude-code-tui.raw',
      ).readAsStringSync();
      expect(bytes.contains('esc to interrupt'), isFalse);

      final terminal = Terminal(maxLines: 10000)..resize(120, 30);
      terminal.write(bytes.substring(0, (bytes.length * 0.5).round()));
      expect(
        terminalTailLines(terminal).join('\n'),
        contains('esc to interrupt'),
      );
    });
  });

  group('Claude Code, from a real PTY capture', () {
    test('reports working mid-turn', () {
      expect(
        classify('claude-code-tui', 0.5)?.status,
        AgentActivityStatus.working,
      );
      expect(
        classify('claude-code-tui', 0.7)?.status,
        AgentActivityStatus.working,
      );
    });

    test('reports idle before the turn and after it', () {
      expect(
        classify('claude-code-tui', 0.3)?.status,
        AgentActivityStatus.idle,
      );
      expect(
        classify('claude-code-tui', 0.85)?.status,
        AgentActivityStatus.idle,
      );
    });

    test('the whole run is a working-then-idle transition', () {
      final states = [
        for (final f in [0.3, 0.5, 0.7, 0.85])
          classify('claude-code-tui', f)!.status,
      ];
      expect(states, [
        AgentActivityStatus.idle,
        AgentActivityStatus.working,
        AgentActivityStatus.working,
        AgentActivityStatus.idle,
      ]);
    });

    test('a modal waiting for the user reports awaitingApproval', () {
      // The workspace-trust prompt: `Enter to confirm · Esc to cancel`.
      final report = classify('claude-code-trust-prompt', 1.0);
      expect(report?.status, AgentActivityStatus.awaitingApproval);
      expect(report?.source, AgentStatusSource.terminalGrid);
    });

    test('a prompt drawn over a spinner reads as waiting, not working', () {
      // Ordering, not patterns, is what makes this right: the footer that says
      // `shift+tab to cycle` is on screen while working too.
      final descriptor = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
      final report = const TerminalGridStatusSource().read(
        descriptor,
        const [
          '  Enter to confirm · Esc to cancel',
          '  accept edits on (shift+tab to cycle) · esc to interrupt',
        ],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      );
      expect(report?.status, AgentActivityStatus.awaitingApproval);
    });
  });

  group('Codex, from a real PTY capture', () {
    test('reports working while its status line says so', () {
      for (final f in [0.35, 0.5, 0.65, 0.8]) {
        expect(
          classify('codex-tui', f)?.status,
          AgentActivityStatus.working,
          reason: 'at $f',
        );
      }
    });

    test('claims nothing once it stops saying it is working', () {
      // Codex declares no idle marker, because its idle screen has none this
      // source could tell apart from a busy one. `null` here is the source
      // declining, which lets the status service fall through to the rollout
      // file rather than being handed a guess.
      expect(classify('codex-tui', 1.0), isNull);
    });
  });

  test('an agent with no declared grid rules is never classified', () {
    final antigravity = AgentRegistry.builtIn.byId(AgentIds.antigravity)!;
    expect(antigravity.grid.isEmpty, isTrue);
    expect(
      const TerminalGridStatusSource().read(
        antigravity,
        const ['esc to interrupt', 'Enter to confirm'],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      ),
      isNull,
    );
  });

  test('an empty screen is not classified', () {
    final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
    expect(
      const TerminalGridStatusSource().read(
        claude,
        const [],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      ),
      isNull,
    );
  });
}
