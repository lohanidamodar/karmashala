import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

import 'fixture_menu_screen.dart';
import 'screen_rows.dart';

class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 9, 9);
}

/// The tool permissions each terminal agent asks on its own screen, captured
/// live on 2026-10-09 (Claude Code 2.1.287 and Codex 0.160.0 in a ConPTY,
/// agy 1.3.2 through WSL): each needs you, reads as a menu, and is answered
/// by its own yes and no.
void main() {
  final registry = AgentRegistry.builtIn;

  for (final (agentId, fixture, marker, yes, no, asks) in [
    (
      AgentIds.claudeCode,
      'claude-code-permission-2.1.287',
      '❯',
      'Yes',
      // Its Esc is a safe no at a tool permission (measured).
      'Deny',
      'Do you want to proceed?',
    ),
    (
      AgentIds.codex,
      'codex-exec-approval-0.160',
      '›',
      'Yes, proceed (y)',
      'No, and tell Codex what to do differently (esc)',
      'Would you like to run the following command?',
    ),
    (
      AgentIds.codex,
      'codex-edit-approval-0.160',
      '›',
      'Yes, proceed (y)',
      'No, and tell Codex what to do differently (esc)',
      'Would you like to make the following edits?',
    ),
    (
      AgentIds.antigravity,
      'antigravity-permission-prompt',
      '>',
      'Yes, run command',
      'No, cancel',
      'Run this command?',
    ),
  ]) {
    group('$agentId: $fixture.raw', () {
      final agent = registry.byId(agentId)!;

      test('needs you, and the menu card quotes the question', () {
        final keeper = HostedStatusKeeper(agents: registry, clock: _Clock())
          ..track('row-1', agentId: agentId);
        final report = keeper
            .screen(
              'row-1',
              terminalTailLines(
                fixtureScreen(fixture),
                lines: agent.grid.scanLines,
              ),
            )!
            .report;
        expect(report.status, AgentActivityStatus.awaitingApproval);
        expect(report.waiting, AgentWaitKind.approval);
        expect(report.hasOpenPrompt, isTrue);
        // The card quotes the menu's own prompt rows, read further up than
        // the status's scan.
        final menu = readScreenMenu(
          FixtureMenuScreen.fixture(fixture, marker: marker).rows(),
          agent.menus!,
        )!;
        expect(menu.prompt.join(' '), contains(asks));
      });

      SessionApprovalAnswerer answerer(FixtureMenuScreen screen) =>
          SessionApprovalAnswerer(
            menus: SessionMenuAnswerer(
              readScreen: (_) => screen.rows(),
              supportFor: (_) => agent.menus,
              isAsking: (_) => true,
              press: (_, keys) => screen.press(keys),
              poll: const Duration(milliseconds: 1),
              patience: const Duration(milliseconds: 300),
            ),
            rulesFor: (_) => agent.approval,
            agentNameFor: (_) => agent.displayName,
            hasOpenQuestion: (_) => false,
            pressAnswerKey:
                (_, keys, {required decidedBy, required decidedBySessionId}) =>
                    screen.press(keys),
            recordMenuAnswer:
                (
                  _, {
                  required granted,
                  required option,
                  required effect,
                  required decidedBy,
                  required decidedBySessionId,
                }) {},
          );

      test('approve chooses "$yes"', () async {
        final screen = FixtureMenuScreen.fixture(fixture, marker: marker);
        final answer = await answerer(screen).answer('s', approve: true);
        expect(answer.answered, yes);
        expect(screen.confirmed, yes);
      });

      test('deny chooses "$no"', () async {
        final screen = FixtureMenuScreen.fixture(fixture, marker: marker);
        final answer = await answerer(screen).answer('s', approve: false);
        expect(answer.answered, no);
        if (no == 'Deny') {
          expect(screen.sent, ['\x1b']);
        } else {
          expect(screen.confirmed, no);
        }
      });
    });
  }
}
