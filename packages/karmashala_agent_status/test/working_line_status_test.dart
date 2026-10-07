import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

class _Clock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 7, 9);
  @override
  DateTime nowUtc() => now;
}

/// The agent's working line, read off the screen the host holds and carried
/// on the status it already sends — whichever source gave the status.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  late _Clock clock;
  late HostedStatusKeeper keeper;

  setUp(() {
    clock = _Clock();
    keeper = HostedStatusKeeper(agents: AgentRegistry.builtIn, clock: clock)
      ..track('row-1', agentId: claude.id);
  });

  HostedAgentStatus? hook(
    String event, [
    Map<String, Object?> more = const {},
  ]) {
    final body = jsonEncode({
      'session_id': 'conv-1',
      'hook_event_name': event,
      ...more,
    });
    final report = keeper.classify(
      agentId: claude.id,
      event: event,
      body: body,
      receivedAt: clock.now,
    );
    return keeper.hookLanded('row-1', report, body: body);
  }

  List<String> screen(String spinner) => [
    '● Reading the tests.',
    '',
    spinner,
    '',
    '──────────────────────────────',
    '❯ ',
    '──────────────────────────────',
    '  ⏸ manual mode on · esc to interrupt',
  ];

  test('a hook says working; the screen says the word, time and tokens', () {
    hook('UserPromptSubmit');
    clock.now = clock.now.add(const Duration(seconds: 3));
    final moved = keeper.screen(
      'row-1',
      screen('✻ Sautéing… (2s · ↓ 7 tokens)'),
    );

    final working = moved!.report.working!;
    expect(moved.report.source, AgentStatusSource.hook);
    expect(working.word, 'Sautéing…');
    expect(working.since, clock.now.subtract(const Duration(seconds: 2)));
    expect(working.tokens, 7);
  });

  test('a screen alone gives both the status and the line', () {
    final moved = keeper.screen(
      'row-1',
      screen('✻ Booping… (1m 12s · ↑ 1.2k tokens · esc to interrupt)'),
    );
    expect(moved!.report.status, AgentActivityStatus.working);
    expect(moved.report.working!.word, 'Booping…');
    expect(moved.report.working!.tokens, 1200);
  });

  test('the seconds ticking on is not news; a new token count is', () {
    keeper.screen('row-1', screen('✻ Sautéing… (2s · ↓ 7 tokens)'));
    clock.now = clock.now.add(const Duration(seconds: 1));
    expect(
      keeper.screen('row-1', screen('✻ Sautéing… (3s · ↓ 7 tokens)')),
      isNull,
      reason: 'the same start, read a second later',
    );
    clock.now = clock.now.add(const Duration(seconds: 1));
    expect(
      keeper.screen('row-1', screen('✻ Sautéing… (4s · ↓ 12 tokens)')),
      isNotNull,
    );
  });

  test('thousands move only when the label would', () {
    keeper.screen('row-1', screen('✻ Sautéing… (9s · ↓ 1.2k tokens)'));
    clock.now = clock.now.add(const Duration(seconds: 1));
    expect(
      keeper.screen('row-1', screen('✻ Sautéing… (10s · ↓ 1,260 tokens)')),
      isNull,
    );
    clock.now = clock.now.add(const Duration(seconds: 1));
    expect(
      keeper.screen('row-1', screen('✻ Sautéing… (11s · ↓ 1.3k tokens)')),
      isNotNull,
    );
  });

  test('an ask carries no working line, and the turn after it does', () {
    hook('UserPromptSubmit');
    keeper.screen('row-1', screen('✻ Sautéing… (2s · ↓ 7 tokens)'));
    final asking = hook('Notification', {
      'notification_type': 'permission_prompt',
      'message': 'Claude needs your permission to use Bash',
    });
    expect(asking!.report.hasOpenPrompt, isTrue);
    expect(asking.report.working, isNull);

    final idle = hook('Stop');
    expect(idle!.report.status, AgentActivityStatus.idle);
    expect(idle.report.working, isNull);
  });

  test('a screen with no working line on it says only the status', () {
    final moved = keeper.screen('row-1', [
      '──────────────────────────────',
      '❯ ',
      '  ⏸ manual mode on · esc to interrupt',
    ]);
    expect(moved!.report.status, AgentActivityStatus.working);
    expect(moved.report.working, isNull);
  });

  test('it travels on the wire, and an older report reads without it', () {
    final moved = keeper.screen(
      'row-1',
      screen('✻ Sautéing… (2s · ↓ 7 tokens)'),
    )!;
    final back = HostedAgentStatus.fromJson(
      jsonDecode(jsonEncode(moved.toJson())),
    )!;
    expect(back.report.working!.word, 'Sautéing…');
    expect(back.report.working!.since, moved.report.working!.since);
    expect(back.report.working!.tokens, 7);

    final older = moved.toJson();
    (older['report']! as Map<String, Object?>).remove('working');
    expect(HostedAgentStatus.fromJson(older)!.report.working, isNull);
  });
}
