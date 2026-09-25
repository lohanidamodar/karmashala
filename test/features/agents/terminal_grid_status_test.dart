import 'dart:io';

import 'package:karmashala_agent_reporting/status.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

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

/// Whether [fraction] of a captured stream leaves the agent at its first-run
/// question, as the daemon reads it: the declared markers over the screen.
bool atFirstRunPrompt(String fixture, double fraction) {
  final bytes = File(
    'test/features/agents/fixtures/$fixture.raw',
  ).readAsStringSync();
  final terminal = Terminal(maxLines: 10000)..resize(120, 40);
  terminal.write(bytes.substring(0, (bytes.length * fraction).round()));
  final rules = AgentRegistry.builtIn
      .byId(fixture.startsWith('codex') ? AgentIds.codex : AgentIds.claudeCode)!
      .launch
      .firstRunPrompt;
  return rules.matchedBy(terminalTailLines(terminal, lines: rules.scanLines));
}

void main() {
  group('the first-run question, from real PTY captures', () {
    test('Claude Code at its folder-trust question', () {
      expect(atFirstRunPrompt('claude-code-trust-prompt', 1.0), isTrue);
    });

    test('Codex at its directory-trust question', () {
      expect(atFirstRunPrompt('codex-approval-prompt', 0.019), isTrue);
    });

    test('a working or idle Claude Code is not at it', () {
      for (final fraction in [0.3, 0.5, 0.85]) {
        expect(atFirstRunPrompt('claude-code-tui', fraction), isFalse);
      }
      expect(atFirstRunPrompt('claude-code-permission-modal', 1.0), isFalse);
    });
  });

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
      // A tool-permission modal. Both it and the workspace-trust modal are real
      // prompts with a highlighted option, and both must keep reaching the
      // buttons that answer them.
      //
      // The footer here is the one v2.1.251 drew; v2.1.258's is
      // `Esc to cancel · Tab to amend` — see the captured fixture below.
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

    test('a real permission modal is still an approval', () {
      // Captured from a real PTY run of Claude Code v2.1.258 answering
      // "create a file called note.txt containing the word hello" under
      // `--permission-mode manual`
      // (`test/features/agents/fixtures/claude-code-permission-modal.raw`).
      //
      // The reason this fixture had to exist: **the tool-permission modal
      // names no "confirm" key at all.** Its footer is
      // `Esc to cancel · Tab to amend`, which is why the bare `Esc to cancel`
      // matcher cannot be dropped however loose it is on its own.
      final report = classify('claude-code-permission-modal', 1.0);
      expect(report?.status, AgentActivityStatus.awaitingApproval);
      expect(report?.waiting, AgentWaitKind.approval);
      expect(
        report!.evidence.join('\n'),
        contains('Do you want to create note.txt?'),
      );
    });

    test('the composer is gone while that modal is up', () {
      // The fact the whole corroboration rule rests on. At 0.9 the turn is
      // still running and the composer footer is drawn; at 1.0 the modal has
      // replaced it and no footer of Claude Code's own is left on screen.
      final terminal = Terminal(maxLines: 10000)..resize(120, 30);
      final bytes = File(
        'test/features/agents/fixtures/claude-code-permission-modal.raw',
      ).readAsStringSync();
      terminal.write(bytes);
      final screen = terminalTailLines(terminal, lines: 12).join('\n');

      expect(screen, contains('Esc to cancel'));
      expect(screen, isNot(contains('esc to interrupt')));
      expect(screen, isNot(contains('shift+tab to cycle')));
      expect(screen, isNot(contains('bypass permissions on')));
    });

    test('the rate-limit banner is not an approval', () {
      // Claude Code 2.1.258 draws this over its own composer while it waits
      // out a usage limit and then continues **by itself**. Read off the
      // shipped binary\'s own strings:
      //
      //   `Usage limit reached ` + ` continuing automatically at ` + ` esc to cancel`
      //
      // Nothing is open, nothing is highlighted, and Enter here does not
      // confirm anything — it submits whatever is in the composer, which is
      // the exact keystroke the Approve button sends.
      final report = const TerminalGridStatusSource().read(
        AgentRegistry.builtIn.byId(AgentIds.claudeCode)!,
        const [
          '● I have finished the analysis and written it up above.',
          '',
          '  \u23f8 Usage limit reached \u00b7 continuing automatically at 5pm '
              '\u00b7 esc to cancel',
          '',
          '\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500',
          '\u276f',
          '\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500',
          '  \u23f5\u23f5 accept edits on (shift+tab to cycle) \u00b7 \u2190 for agents',
        ],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      );

      expect(report?.status, AgentActivityStatus.idle);
      expect(report?.waiting, AgentWaitKind.input);
    });

    test('the agent quoting the footer in a message is not an approval', () {
      // Real rows, from the owner\'s own pane scrollback: this bug report was
      // written *in* Karmashala, and Claude Code printed the matcher strings
      // into its answer while sitting idle at its prompt. The screen matched
      // and an Approve button appeared over a session with nothing open.
      final report = const TerminalGridStatusSource().read(
        AgentRegistry.builtIn.byId(AgentIds.claudeCode)!,
        const [
          '● The grid matchers can fire on ordinary output. Approval is '
              'detected by Enter to confirm + Esc to cancel appearing on the',
          '  rendered screen.',
          '',
          '\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500',
          '\u276f',
          '\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500',
          '  bypass permissions on \u00b7 1 shell \u00b7 \u2190 for agents',
        ],
        DateTime.utc(2026, 8, 30),
        sessionId: 's',
      );

      expect(report?.status, AgentActivityStatus.idle);
      expect(report?.waiting, AgentWaitKind.input);
    });

    test('a prompt drawn over a composer is not a prompt at all', () {
      // This screen used to be asserted the other way round, from a
      // hand-written pair of rows and the assumption that a modal can sit over
      // the composer. The capture says otherwise: a modal replaces it, so a
      // screen showing both is a screen where those words are text.
      //
      // **What this now cannot detect**: a real modal an agent draws *without*
      // taking its composer footer down. Nothing captured does that, and the
      // cost of being wrong runs the other way — the terminal still shows the
      // prompt and the user answers it there, whereas an Approve button offered
      // over a live composer types Enter into it.
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
      expect(report?.status, AgentActivityStatus.working);
      expect(report?.waiting, AgentWaitKind.unrecorded);
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
