import 'dart:io';

import 'package:karmashala/src/features/agents/data/terminal_grid_status_source.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
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
      expect(report?.waiting, AgentWaitKind.approval);
    });

    test('the idle footer of a bypass session is not an approval', () {
      // The owner's live screen at the moment the app claimed an approval was
      // pending. Nothing is highlighted and nothing is open to confirm, and the
      // footer does not mention shift+tab at all: bypass mode replaces that
      // segment, which is why this screen used to match no rule.
      final report = const TerminalGridStatusSource().read(
        AgentRegistry.builtIn.byId(AgentIds.claudeCode)!,
        const [
          '> ',
          '  bypass permissions on \u00b7 1 shell \u00b7 \u2190 for agents \u00b7 \u2193 to manage',
        ],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      );

      expect(report?.status, AgentActivityStatus.idle);
      expect(report?.waiting, AgentWaitKind.input);
    });

    test('a permission prompt still says an approval is open', () {
      // A tool-permission modal, which ends in the same pair the workspace
      // trust modal does. Both are real prompts with a highlighted option, and
      // both must keep reaching the buttons that answer them.
      final report = const TerminalGridStatusSource().read(
        AgentRegistry.builtIn.byId(AgentIds.claudeCode)!,
        const [
          '  Bash command',
          '  rm -rf build/',
          '',
          '  Do you want to proceed?',
          '  \u276f 1. Yes',
          '    2. No, and tell Claude what to do differently',
          '',
          '  Enter to confirm \u00b7 Esc to cancel',
        ],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      );

      expect(report?.status, AgentActivityStatus.awaitingApproval);
      expect(report?.waiting, AgentWaitKind.approval);
    });

    test('the captured idle screen waits on input, never on an approval', () {
      for (final fraction in [0.3, 0.85]) {
        final report = classify('claude-code-tui', fraction);
        expect(report?.status, AgentActivityStatus.idle, reason: '$fraction');
        expect(report?.waiting, AgentWaitKind.input, reason: '$fraction');
      }
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

    test('its directory-trust modal reports awaitingApproval', () {
      // Observed live in a PTY pane: Codex blocks on this before it will start
      // at all, so a session sitting here is waiting for the user, not working.
      final report = const TerminalGridStatusSource().read(
        AgentRegistry.builtIn.byId(AgentIds.codex)!,
        const [
          '  Do you trust the contents of this directory?',
          '',
          '\u203a 1. Yes, continue',
          '  2. No, quit',
          '',
          '  Press enter to continue',
        ],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      );
      expect(report?.status, AgentActivityStatus.awaitingApproval);
      expect(report?.source, AgentStatusSource.terminalGrid);
      expect(report?.waiting, AgentWaitKind.approval);
      // The asymmetry this whole type exists for: Codex's prompt names Enter
      // and names no way to decline, which is a different question from whether
      // a prompt is open at all.
      final rules = AgentRegistry.builtIn.byId(AgentIds.codex)!.approval;
      expect(rules.approve, isNotNull);
      expect(rules.deny, isNull);
    });

    test('a working Codex screen claims nothing about a prompt', () {
      expect(classify('codex-tui', 0.5)?.waiting, AgentWaitKind.unrecorded);
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
