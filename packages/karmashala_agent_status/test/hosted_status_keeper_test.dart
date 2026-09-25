import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:test/test.dart';

import 'screen_rows.dart';

class _Clock implements Clock {
  DateTime now = DateTime.utc(2026, 9, 25, 9);
  @override
  DateTime nowUtc() => now;
}

/// The status the session host keeps for a session it holds, from what it
/// sees for itself: the hooks the agent fires, then its own screen, read by the
/// agent's adapter. The same precedence the app's registry applies, with no
/// transcript: a hook first, a screen showing a prompt or a failure next, the
/// rest of the screen after it.
void main() {
  final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;
  final codex = AgentRegistry.builtIn.byId(AgentIds.codex)!;
  late _Clock clock;
  late HostedStatusKeeper keeper;

  setUp(() {
    clock = _Clock();
    keeper = HostedStatusKeeper(agents: AgentRegistry.builtIn, clock: clock);
  });

  String payload(String event, [Map<String, Object?> more = const {}]) =>
      jsonEncode({'session_id': 'conv-1', 'hook_event_name': event, ...more});

  HostedAgentStatus? hook(
    String event, [
    Map<String, Object?> more = const {},
    String sessionId = 'row-1',
  ]) {
    final body = payload(event, more);
    final report = keeper.classify(
      agentId: claude.id,
      event: event,
      body: body,
      receivedAt: clock.now,
    );
    return keeper.hookLanded(sessionId, report, body: body);
  }

  List<String> screenOf(String fixture, double fraction, AgentDescriptor who) =>
      terminalTailLines(
        fixtureScreen(fixture, fraction: fraction),
        lines: who.grid.scanLines,
      );

  group('from hooks', () {
    setUp(() => keeper.track('row-1', agentId: claude.id));

    test('a turn: working, a permission prompt, then idle', () {
      expect(
        keeper.statusOf('row-1')!.report.status,
        AgentActivityStatus.unknown,
      );

      final working = hook('UserPromptSubmit');
      expect(working!.report.status, AgentActivityStatus.working);
      expect(working.report.source, AgentStatusSource.hook);
      expect(working.sessionId, 'row-1');
      expect(working.report.sessionId, 'conv-1', reason: 'the conversation');

      final asking = hook('Notification', {
        'notification_type': 'permission_prompt',
        'message': 'Claude needs your permission to use Bash',
      });
      expect(asking!.report.hasOpenPrompt, isTrue);
      expect(asking.report.evidence, [
        'Claude needs your permission to use Bash',
      ]);

      final idle = hook('Stop');
      expect(idle!.report.status, AgentActivityStatus.idle);
      expect(idle.report.hasOpenPrompt, isFalse);
    });

    test('the same word again is not a change', () {
      expect(hook('UserPromptSubmit'), isNotNull);
      clock.now = clock.now.add(const Duration(seconds: 3));
      expect(hook('UserPromptSubmit'), isNull);
    });

    test('a question travels whole, and the notice after it keeps it', () {
      final asked = hook('PreToolUse', {
        'tool_name': 'AskUserQuestion',
        'tool_use_id': 'toolu_1',
        'tool_input': {
          'questions': [
            {
              'question': 'Pick a fruit',
              'header': 'Fruit',
              'options': [
                {'label': 'Apple'},
                {'label': 'Banana', 'description': 'yellow'},
              ],
            },
          ],
        },
      });
      expect(asked!.report.hasOpenQuestion, isTrue);
      expect(asked.question!.toolUseId, 'toolu_1');
      expect(
        asked.question!.questions.single.options.last.description,
        'yellow',
      );

      hook('Notification', {
        'notification_type': 'permission_prompt',
        'message': 'Claude needs your permission to use AskUserQuestion',
      });
      final still = keeper.statusOf('row-1')!;
      expect(still.report.hasOpenQuestion, isTrue);
      expect(still.question!.toolUseId, 'toolu_1');

      final answered = hook('PostToolUse', {'tool_name': 'AskUserQuestion'});
      expect(answered!.report.hasOpenQuestion, isFalse);
      expect(answered.question, isNull);
    });

    test('a hook naming no row is found by the conversation it names', () {
      hook('UserPromptSubmit');
      expect(keeper.sessionForConversation(claude.id, 'conv-1'), 'row-1');
      expect(keeper.sessionForConversation(codex.id, 'conv-1'), isNull);
    });

    test('an untracked row is not kept', () {
      expect(hook('UserPromptSubmit', const {}, 'row-2'), isNull);
      expect(keeper.statusOf('row-2'), isNull);
    });

    test('the wire shape carries the report and the question back', () {
      hook('PreToolUse', {
        'tool_name': 'AskUserQuestion',
        'tool_use_id': 'toolu_9',
        'tool_input': {
          'questions': [
            {
              'question': 'Ship it?',
              'options': ['Yes', 'No'],
            },
          ],
        },
      });
      final sent = keeper.statusOf('row-1')!;
      final back = HostedAgentStatus.fromJson(
        jsonDecode(jsonEncode(sent.toJson())),
      )!;
      expect(back.sessionId, 'row-1');
      expect(sameStatusEvidence(back.report, sent.report), isTrue);
      expect(back.report.waiting, AgentWaitKind.question);
      expect(back.question!.toolUseId, 'toolu_9');
      expect(back.question!.questions.single.options.map((o) => o.label), [
        'Yes',
        'No',
      ]);
    });
  });

  group('from the screen, real PTY captures', () {
    test('Claude Code working, then idle, then at a permission modal', () {
      keeper.track('row-1', agentId: claude.id);

      final working = keeper.screen(
        'row-1',
        screenOf('claude-code-tui', 0.5, claude),
      );
      expect(working!.report.status, AgentActivityStatus.working);
      expect(working.report.source, AgentStatusSource.terminalGrid);

      final idle = keeper.screen(
        'row-1',
        screenOf('claude-code-tui', 0.85, claude),
      );
      expect(idle!.report.status, AgentActivityStatus.idle);
      expect(idle.report.waiting, AgentWaitKind.input);

      final modal = keeper.screen(
        'row-1',
        screenOf('claude-code-permission-modal', 1.0, claude),
      );
      expect(modal!.report.hasOpenPrompt, isTrue);
      expect(
        modal.report.evidence.join('\n'),
        contains('Do you want to create note.txt?'),
      );
    });

    test('Codex at its approval prompt', () {
      keeper.track('row-c', agentId: codex.id);
      final report = keeper
          .screen('row-c', screenOf('codex-approval-prompt', 0.019, codex))
          ?.report;
      expect(report?.status, AgentActivityStatus.awaitingApproval);
    });

    test('a fresh hook outranks the screen, a stale one does not', () {
      keeper.track('row-1', agentId: claude.id);
      final idleScreen = screenOf('claude-code-tui', 0.85, claude);
      hook('UserPromptSubmit');
      expect(
        keeper.screen('row-1', idleScreen),
        isNull,
        reason: 'still working',
      );

      clock.now = clock.now.add(const Duration(minutes: 6));
      final stale = keeper.screen('row-1', idleScreen);
      expect(stale!.report.status, AgentActivityStatus.idle);
      expect(stale.report.source, AgentStatusSource.terminalGrid);
    });

    test(
      'a fresh working hook outranks a modal until the prompt\'s own hook',
      () {
        keeper.track('row-1', agentId: claude.id);
        hook('PreToolUse', {'tool_name': 'Write'});
        // The hook is fresh, and it wins: the approval arrives as its own hook.
        final modal = screenOf('claude-code-permission-modal', 1.0, claude);
        expect(
          keeper.screen('row-1', modal)?.report.status ??
              keeper.statusOf('row-1')!.report.status,
          AgentActivityStatus.working,
        );
        hook('Notification', {
          'notification_type': 'permission_prompt',
          'message': 'Claude needs your permission to use Write',
        });
        expect(keeper.statusOf('row-1')!.report.hasOpenPrompt, isTrue);
      },
    );

    test('an agent no adapter knows stays unknown', () {
      keeper.track('row-x', agentId: 'nobody');
      expect(
        keeper.screen('row-x', screenOf('claude-code-tui', 0.5, claude)),
        isNull,
      );
      expect(
        keeper.statusOf('row-x')!.report.status,
        AgentActivityStatus.unknown,
      );
    });
  });
}
