import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/data/terminal_grid_status_source.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What the app is allowed to say about a pending approval, and how it may be
/// answered.
///
/// The rule under test throughout: **the agent's own words or nothing**. Every
/// assertion about content here checks that we quoted something the agent
/// produced, and every assertion about an absent answer checks that we declined
/// to guess a key binding rather than shipping a plausible one.
void main() {
  const registry = AgentRegistry.builtIn;
  final now = DateTime.utc(2026, 8, 30);

  group('the grid source quotes the screen it read', () {
    // A Claude Code permission modal as it is actually drawn: the question, the
    // choices, then the footer the matcher fires on.
    const modal = [
      'Claude wants to run:',
      '  rm -rf build/',
      '',
      '  1. Yes',
      '  2. Yes, and do not ask again',
      '  3. No, tell Claude what to do differently',
      '                                            ',
      'Enter to confirm · Esc to cancel',
    ];

    test('an approval carries the rows, not just the matcher', () {
      final report = const TerminalGridStatusSource().read(
        registry.byId(AgentIds.claudeCode)!,
        modal,
        now,
        sessionId: 's',
      )!;

      expect(report.status, AgentActivityStatus.awaitingApproval);
      // `detail` is still the needle — it explains the verdict.
      expect(report.detail, 'Enter to confirm');
      // ...and `evidence` is the haystack, which is what the user needs. Before
      // this the rows were in scope and dropped, so the app could say an
      // approval was pending and never what for.
      expect(report.evidence, contains('  rm -rf build/'));
      expect(report.evidence, contains('Claude wants to run:'));
    });

    test('blank rows are dropped and nothing else is interpreted', () {
      final report = const TerminalGridStatusSource().read(
        registry.byId(AgentIds.claudeCode)!,
        modal,
        now,
        sessionId: 's',
      )!;

      // Deciding which row is "the question" would be guessing at a TUI's
      // layout, and a wrong guess misdescribes what the user is authorising.
      // So: every non-blank row, in screen order, and no editing beyond
      // trailing whitespace.
      expect(
        report.evidence,
        modal.where((l) => l.trim().isNotEmpty).map((l) => l.trimRight()),
      );
    });

    test('a working screen carries no evidence', () {
      final report = const TerminalGridStatusSource().read(
        registry.byId(AgentIds.claudeCode)!,
        const ['esc to interrupt'],
        now,
        sessionId: 's',
      )!;

      // Evidence exists to say what is being *asked*. Carrying a screenful of
      // text through a 1.2-second poll to describe a spinner is cost with no
      // reader.
      expect(report.status, AgentActivityStatus.working);
      expect(report.evidence, isEmpty);
    });
  });

  group('the hook source quotes the payload', () {
    AgentHookReceiver receiver() => AgentHookReceiver(
      registry: registry,
      reports: AgentHookReports(),
      clock: FixedClock(testTime),
    );

    test("Claude Code's notification message is carried", () {
      final report = receiver().handle(
        agentId: AgentIds.claudeCode,
        event: 'Notification',
        body:
            '{"session_id":"abc",'
            '"message":"Claude needs your permission to use Bash"}',
      );

      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.sessionId, 'abc');
      // Decoded for the session id and then thrown away, until now.
      expect(report.evidence, ['Claude needs your permission to use Bash']);
    });

    test('a payload with no message yields no evidence, not a placeholder', () {
      final report = receiver().handle(
        agentId: AgentIds.claudeCode,
        event: 'Notification',
        body: '{"session_id":"abc"}',
      );

      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.evidence, isEmpty);
    });

    test('an unparseable body is still a report, with nothing quoted', () {
      // A hook must never block the agent that fired it, so this stays a
      // classification rather than an error — it simply has nothing to say.
      final report = receiver().handle(
        agentId: AgentIds.claudeCode,
        event: 'Notification',
        body: 'not json at all',
      );

      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.evidence, isEmpty);
      expect(report.sessionId, '');
    });
  });

  group('answers are declared, never guessed', () {
    test('Claude Code declares both keys, from its own footer', () {
      final approval = registry.byId(AgentIds.claudeCode)!.approval;
      // The same footer `AgentGridRules.awaitingApproval` matches on:
      // "Enter to confirm · Esc to cancel".
      expect(approval.approve!.keys, '\r');
      expect(approval.deny!.keys, '\x1b');
      // And each says what the key does, because Enter confirms whichever
      // option is highlighted rather than a fixed "yes" — the user is
      // authorising a keystroke and should be told which.
      expect(approval.approve!.effect, contains('highlighted'));
      expect(approval.deny!.effect, contains('cancels'));
    });

    test('Codex declares only the key its prompt names', () {
      final approval = registry.byId(AgentIds.codex)!.approval;
      // "Press enter to continue" — verified against a real trust modal in
      // Loop 41's integration test.
      expect(approval.approve!.keys, '\r');
      // Codex's prompt names no way to decline. Esc would be a guess at another
      // program's key bindings, pressed on the user's behalf, so there is no
      // Deny button and the UI sends them to the terminal instead.
      expect(approval.deny, isNull);
      expect(approval.isEmpty, isFalse);
    });

    test('an agent whose prompt we have never read declares nothing', () {
      // The rule, tested against a descriptor written for it rather than
      // against whichever shipped agent happens to be least documented today.
      // It used to be Antigravity, which has since told us its keys (below), so
      // pinning the rule to that agent made it a fact about our research rather
      // than about the default.
      const unexamined = AgentDescriptor(
        id: 'unexamined',
        displayName: 'Unexamined Agent',
        binaries: AgentBinaries(windows: ['x'], posix: ['x']),
      );
      expect(unexamined.approval.isEmpty, isTrue);
    });

    test('Antigravity declares nothing, on evidence rather than by default', () {
      // Its 1.0.13 build wrote a `keybindings.json` binding `confirm.yes` to
      // `y` and `confirm.no` to `n`, which briefly looked like the best-sourced
      // approval keys in the registry. 1.1.22 ships no such file, so those keys
      // describe a version nobody runs, and the honest answer is still none.
      expect(registry.byId(AgentIds.antigravity)!.approval.isEmpty, isTrue);
    });

    test('every declared key is a control sequence, never prose', () {
      // `answerPrompt` writes these verbatim with no trailing return. A key
      // that was accidentally a word would be typed into the agent's composer.
      for (final descriptor in registry.descriptors) {
        for (final answer in [
          descriptor.approval.approve,
          descriptor.approval.deny,
        ].nonNulls) {
          expect(answer.keys, isNotEmpty, reason: descriptor.id);
          // Every code unit below 0x20: a control character, not a printable
          // one. `trim()` cannot express this — it strips CR but leaves ESC,
          // because ESC is not Unicode whitespace.
          expect(
            answer.keys.codeUnits.every((c) => c < 0x20),
            isTrue,
            reason: '${descriptor.id}: ${answer.keys.codeUnits}',
          );
          expect(answer.label, isNotEmpty);
          expect(answer.effect, isNotEmpty);
        }
      }
    });
  });
}
