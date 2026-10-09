import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

import 'screen_rows.dart';

class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 9, 9);
}

/// The folder-trust menus Codex 0.160 and Antigravity draw before any work,
/// captured from the real CLIs (a ConPTY for Codex, WSL through a ConPTY for
/// agy) and read the way the session host reads a pane. Neither surfaced as
/// a card: Codex's footer and options were reworded, and agy declared no
/// screen rules at all.
void main() {
  final registry = AgentRegistry.builtIn;

  for (final (agentId, fixture, question, options) in [
    (
      AgentIds.codex,
      'codex-trust-prompt-0.160',
      'Trust this folder? Codex can read, edit, and run files here',
      ['Trust and continue', 'Quit'],
    ),
    (
      AgentIds.antigravity,
      'antigravity-trust-prompt',
      'Do you trust the contents of this project?',
      ['Yes, I trust this folder', 'No, exit'],
    ),
  ]) {
    group('$agentId ($fixture.raw)', () {
      final agent = registry.byId(agentId)!;
      late List<String> rows;

      setUp(() {
        rows = terminalTailLines(
          fixtureScreen(fixture),
          lines: agent.grid.scanLines,
        );
      });

      test('needs you: an open approval prompt off the screen', () {
        final keeper = HostedStatusKeeper(agents: registry, clock: _Clock())
          ..track('row-1', agentId: agentId);
        final status = keeper.screen('row-1', rows)!.report;
        expect(status.status, AgentActivityStatus.awaitingApproval);
        expect(status.waiting, AgentWaitKind.approval);
        expect(status.hasOpenPrompt, isTrue);
        expect(status.source, AgentStatusSource.terminalGrid);
        expect(status.evidence.join('\n'), contains(question));
      });

      test('the menu reads whole, the first option highlighted', () {
        final menu = readScreenMenu(rows, agent.menus!)!;
        expect(menu.options, options);
        expect(menu.highlighted, 0);
        expect(menu.isChecklist, isFalse);
        expect(menu.prompt.join(' '), contains(question.split(' ').first));
      });

      test('approve is the first option and deny the second', () {
        final menu = readScreenMenu(rows, agent.menus!)!;
        expect(agent.menus!.affirmativeIn(menu), 0);
        expect(agent.menus!.negativeIn(menu), 1);
      });

      test('it is the folder-trust question an automation stops at', () {
        expect(agent.launch.firstRunPrompt.matchedBy(rows), isTrue);
      });
    });
  }

  test('an idle Antigravity composer is no prompt', () {
    final agy = registry.byId(AgentIds.antigravity)!;
    const idle = [
      '────────────────────────────────────────────────────',
      '> write the tests first',
      '────────────────────────────────────────────────────',
      '? for shortcuts                       Gemini 3.8 Flash · high',
    ];
    final keeper = HostedStatusKeeper(agents: registry, clock: _Clock())
      ..track('row-1', agentId: agy.id);
    expect(
      keeper.screen('row-1', idle)?.report.hasOpenPrompt ?? false,
      isFalse,
    );
    expect(readScreenMenu(idle, agy.menus!), isNull);
    expect(agy.launch.firstRunPrompt.matchedBy(idle), isFalse);
  });
}
