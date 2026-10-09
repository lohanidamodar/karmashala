import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

import 'screen_rows.dart';

class _Clock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 9, 9);
  @override
  DateTime nowUtc() => now;
}

/// agy 1.3.2's own screens, captured through WSL in a ConPTY: a tool
/// permission it asks on screen only, and the idle composer after an Esc
/// ("⎿ Interrupted"). A terminal Antigravity child whose turn ended that way
/// read "working" for good — its queue never delivered and its parent heard
/// nothing (session 038649f1, 2026-10-09).
void main() {
  final registry = AgentRegistry.builtIn;
  final agy = registry.byId(AgentIds.antigravity)!;
  late _Clock clock;
  late HostedStatusKeeper keeper;

  setUp(() {
    clock = _Clock();
    keeper = HostedStatusKeeper(agents: registry, clock: clock)
      ..track('row-1', agentId: agy.id);
  });

  List<String> rows(String fixture) =>
      terminalTailLines(fixtureScreen(fixture), lines: agy.grid.scanLines);

  void hook(String event) {
    final body = jsonEncode({
      'conversationId': 'conv-1',
      'workspacePaths': ['/tmp/r70-probe-agy'],
    });
    final report = keeper.classify(
      agentId: agy.id,
      event: event,
      body: body,
      receivedAt: clock.now,
    );
    keeper.hookLanded('row-1', report, body: body);
  }

  group('a tool permission (antigravity-permission-prompt.raw)', () {
    test('needs you, as a menu whose yes and no are named', () {
      final screen = rows('antigravity-permission-prompt');
      hook('PreInvocation');
      clock.now = clock.now.add(const Duration(seconds: 1));
      final report = keeper.screen('row-1', screen)!.report;
      expect(report.status, AgentActivityStatus.awaitingApproval);
      expect(report.hasOpenPrompt, isTrue);
      expect(report.evidence.join('\n'), contains('Run this command?'));

      final menu = readScreenMenu(screen, agy.menus!)!;
      expect(menu.options.first, 'Yes, run command');
      expect(menu.options.last, 'No, cancel');
      expect(menu.options, hasLength(4));
      expect(agy.menus!.affirmativeIn(menu), 0);
      expect(agy.menus!.negativeIn(menu), 3);
    });
  });

  group('an Esc mid-turn (antigravity-interrupted.raw)', () {
    test('with no hook the screen reads idle, waiting for input', () {
      final report = keeper.screen('row-1', rows('antigravity-interrupted'))!;
      expect(report.report.status, AgentActivityStatus.idle);
      expect(report.report.hasOpenPrompt, isFalse);
    });

    test('a fresh "working" hook still stands; once it is stale the idle '
        'screen wins', () {
      hook('PreInvocation');
      final screen = rows('antigravity-interrupted');
      clock.now = clock.now.add(const Duration(seconds: 30));
      expect(
        keeper.screen('row-1', screen)?.report.status ??
            keeper.statusOf('row-1')!.report.status,
        AgentActivityStatus.working,
      );
      clock.now = clock.now.add(const Duration(minutes: 6));
      expect(
        keeper.screen('row-1', screen)?.report.status ??
            keeper.statusOf('row-1')!.report.status,
        AgentActivityStatus.idle,
      );
    });

    test('a Stop hook reads idle at once', () {
      hook('PreInvocation');
      clock.now = clock.now.add(const Duration(seconds: 5));
      hook('Stop');
      expect(keeper.statusOf('row-1')!.report.status, AgentActivityStatus.idle);
    });
  });

  test("Claude Code's and Codex's footers are not agy's idle", () {
    // A pane is adopted by the one agent whose screen it shows: a footer two
    // agents claim is claimed by neither.
    for (final footer in [
      '  ? for shortcuts · shift+tab to cycle',
      '⏸ manual mode on · ? for shortcuts            /rc connecting…',
      '  ? for shortcuts',
    ]) {
      expect(agy.grid.idle.any((m) => m.matches(footer)), isFalse);
    }
    expect(
      agy.grid.idle.any(
        (m) => m.matches('? for shortcuts          Gemini 3.8 Flash · high'),
      ),
      isTrue,
    );
  });
}
