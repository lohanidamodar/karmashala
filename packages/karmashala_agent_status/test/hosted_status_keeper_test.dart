import 'dart:convert';
import 'dart:io';

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

    test('a question stays open while background agents work', () {
      hook('PreToolUse', {
        'tool_name': 'AskUserQuestion',
        'tool_use_id': 'toolu_1',
        'tool_input': {
          'questions': [
            {
              'question': 'Pick a fruit',
              'options': [
                {'label': 'Apple'},
              ],
            },
          ],
        },
      });
      for (final event in ['PreToolUse', 'PostToolUse', 'PreToolUse']) {
        clock.now = clock.now.add(const Duration(seconds: 1));
        hook(event, {
          'agent_id': 'a8989a29',
          'tool_name': 'Bash',
          'tool_use_id': 'toolu_sub',
        });
      }
      final still = keeper.statusOf('row-1')!;
      expect(still.report.hasOpenQuestion, isTrue);
      expect(still.question!.toolUseId, 'toolu_1');
    });

    test('a protocol report that is a question keeps the question it asks, '
        'until the agent moves on', () {
      AgentStatusReport protocol(AgentActivityStatus status, AgentWaitKind w) =>
          AgentStatusReport(
            agentId: claude.id,
            sessionId: 'conv-1',
            status: status,
            source: AgentStatusSource.protocol,
            observedAt: clock.now,
            waiting: w,
          );
      final set = AgentQuestionSet.fromToolInput('q1', {
        'questions': [
          {
            'question': 'Which fruits?',
            'multiSelect': true,
            'options': [
              {'label': 'Apple'},
              {'label': 'Pear'},
            ],
          },
        ],
      })!;
      final asked = keeper.report(
        'row-1',
        protocol(AgentActivityStatus.awaitingApproval, AgentWaitKind.question),
        question: set,
      );
      expect(asked!.report.hasOpenQuestion, isTrue);
      expect(asked.question!.questions.single.multiSelect, isTrue);

      clock.now = clock.now.add(const Duration(seconds: 1));
      final moved = keeper.report(
        'row-1',
        protocol(AgentActivityStatus.working, AgentWaitKind.unrecorded),
      );
      expect(moved!.question, isNull);
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
              'options': [
                'Yes',
                {'label': 'No', 'preview': '```\nnot yet\n```'},
              ],
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
      expect(back.question!.questions.single.options.map((o) => o.preview), [
        '',
        '```\nnot yet\n```',
      ]);
    });
  });

  // Round 64, 2026-10-08: a child ran `claude -p` from its Bash tool, and
  // each nested Stop read as the child finishing its turn.
  group('a hook from another conversation in the pane', () {
    setUp(() => keeper.track('row-1', agentId: claude.id));

    test('mid-turn is an agent the pane ran, not the pane', () {
      hook('UserPromptSubmit');
      hook('PreToolUse', {'tool_name': 'Bash'});
      expect(keeper.ownsConversation('row-1', 'conv-1'), isTrue);
      expect(keeper.ownsConversation('row-1', 'nested'), isFalse);
      expect(keeper.ownsConversation('row-1', ''), isTrue);
    });

    test('while its background work runs is not the pane either', () {
      hook('UserPromptSubmit');
      hook('Stop', {
        'background_tasks': [
          {'type': 'shell', 'status': 'running', 'command': 'claude -p hi'},
        ],
      });
      expect(keeper.ownsConversation('row-1', 'nested'), isFalse);
    });

    test('at rest is the pane moving on (/clear, /resume)', () {
      hook('UserPromptSubmit');
      hook('Stop');
      expect(keeper.ownsConversation('row-1', 'conv-2'), isTrue);
    });
  });

  // Found on a real phone, Claude Code 2.1.283, desktop app closed: every
  // surface (the phone's inbox, the desktop's `session_wait`, MCP) reads this
  // keeper, so what it says of a hook is what they all say.
  group('Claude Code\'s Notification, by its notification_type', () {
    setUp(() => keeper.track('row-1', agentId: claude.id));

    test('"waiting for your input" is idle, never awaitingApproval', () {
      hook('UserPromptSubmit');
      hook('Stop');
      clock.now = clock.now.add(const Duration(seconds: 60));
      hook('Notification', {
        'notification_type': 'idle_prompt',
        'message': 'Claude is waiting for your input',
      });
      final kept = keeper.statusOf('row-1')!.report;
      expect(kept.status, AgentActivityStatus.idle);
      expect(kept.hasOpenPrompt, isFalse);
      expect(kept.hasOpenQuestion, isFalse);
    });

    test('"needs your permission" is awaitingApproval, an open prompt', () {
      hook('PreToolUse', {'tool_name': 'Bash'});
      final asking = hook('Notification', {
        'notification_type': 'permission_prompt',
        'message': 'Claude needs your permission to use Bash',
      });
      expect(asking!.report.status, AgentActivityStatus.awaitingApproval);
      expect(asking.report.waiting, AgentWaitKind.approval);
      expect(asking.report.hasOpenPrompt, isTrue);
    });
  });

  group('a menu drawn under the idle footer after the turn', () {
    // `claude-code-auto-mode-offer.raw`: the real idle screen of
    // `claude-code-tui.raw`, then the "Teach auto mode about your
    // environment?" offer 2.1.283 drew below its footer, as the phone report
    // transcribed it.
    late List<String> offer;

    setUp(() {
      keeper.track('row-1', agentId: claude.id);
      offer = screenOf('claude-code-auto-mode-offer', 1.0, claude);
    });

    test('is an open prompt, although the turn\'s Stop is fresh', () {
      hook('UserPromptSubmit');
      hook('Stop');
      clock.now = clock.now.add(const Duration(seconds: 1));
      final asking = keeper.screen('row-1', offer);
      expect(asking!.report.status, AgentActivityStatus.awaitingApproval);
      expect(asking.report.waiting, AgentWaitKind.approval);
      expect(asking.report.source, AgentStatusSource.terminalGrid);
      expect(
        asking.report.evidence.join('\n'),
        contains('Teach auto mode about your environment?'),
      );

      // Claude's idle nudge a minute later repeats the Stop: it does not put
      // the session back to idle, not even until the next screen.
      clock.now = clock.now.add(const Duration(seconds: 60));
      expect(
        hook('Notification', {
          'notification_type': 'idle_prompt',
          'message': 'Claude is waiting for your input',
        }),
        isNull,
      );
      expect(keeper.statusOf('row-1')!.report.hasOpenPrompt, isTrue);
      keeper.screen('row-1', offer);
      expect(keeper.statusOf('row-1')!.report.hasOpenPrompt, isTrue);
    });

    test('a screen read before the Stop does not outrank it', () {
      keeper.screen('row-1', offer);
      clock.now = clock.now.add(const Duration(seconds: 1));
      final idle = hook('Stop');
      expect(idle!.report.status, AgentActivityStatus.idle);
      expect(idle.report.source, AgentStatusSource.hook);
    });

    test('answered, the idle screen is idle again', () {
      hook('Stop');
      clock.now = clock.now.add(const Duration(seconds: 1));
      expect(keeper.screen('row-1', offer)!.report.hasOpenPrompt, isTrue);
      clock.now = clock.now.add(const Duration(seconds: 1));
      final back = keeper.screen(
        'row-1',
        screenOf('claude-code-tui', 0.85, claude),
      );
      expect(back!.report.status, AgentActivityStatus.idle);
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

    test('a permission prompt drawn while the turn runs is the word, though '
        'no hook said so', () {
      // A second prompt in one turn: the hooks said working, and the prompt
      // came after them with no notification of its own.
      keeper.track('row-1', agentId: claude.id);
      hook('UserPromptSubmit');
      clock.now = clock.now.add(const Duration(seconds: 2));
      final modal = keeper.screen(
        'row-1',
        screenOf('claude-code-permission-modal', 1.0, claude),
      );
      expect(modal!.report.hasOpenPrompt, isTrue);
      expect(modal.report.source, AgentStatusSource.terminalGrid);
    });

    test('a turn the screen shows running well after the Stop is working, '
        'though no hook started it', () {
      // A background task's notice wakes the agent; no UserPromptSubmit fires.
      keeper.track('row-1', agentId: claude.id);
      final workingScreen = screenOf('claude-code-tui', 0.5, claude);
      hook('Stop');
      clock.now = clock.now.add(const Duration(milliseconds: 500));
      expect(
        keeper.screen('row-1', workingScreen),
        isNull,
        reason: 'a screen just after the Stop may not have redrawn yet',
      );
      clock.now = clock.now.add(const Duration(seconds: 5));
      final woke = keeper.screen('row-1', workingScreen);
      expect(woke!.report.status, AgentActivityStatus.working);
      expect(woke.report.source, AgentStatusSource.terminalGrid);
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

    test('a session with a background subagent stays working until it ends', () {
      keeper.track('row-1', agentId: claude.id);
      final idleScreen = screenOf('claude-code-tui', 0.85, claude);
      final running = [
        {
          'id': 'a1',
          'type': 'subagent',
          'status': 'running',
          'description': 'Explore the repository',
        },
      ];
      hook('Stop', {'background_tasks': running});
      clock.now = clock.now.add(const Duration(minutes: 1));
      hook('Notification', {
        'notification_type': 'idle_prompt',
        'message': 'Claude is waiting for your input',
      });

      // The main thread sits at its prompt and nothing fires for a long while.
      clock.now = clock.now.add(const Duration(minutes: 20));
      keeper.screen('row-1', idleScreen);
      final held = keeper.statusOf('row-1')!.report;
      expect(held.status, AgentActivityStatus.working);
      expect(held.inFlight, ['Explore the repository']);

      hook('Stop', {'background_tasks': <Object?>[]});
      final done = keeper.statusOf('row-1')!.report;
      expect(done.status, AgentActivityStatus.idle);
      expect(done.inFlight, isEmpty);
    });

    // A question closed with no hook to say so: the agent's own composer
    // back on screen is then the only word that it closed — on the owner's
    // phone the question stayed open long after. Real screens, Claude Code
    // 2.1.287 in a ConPTY at 120×30 (round 31): the menu replaces the
    // composer's footer while it is drawn, and Esc or "Chat about this"
    // brings the footer back.
    group('a question on a real Claude Code screen', () {
      List<String> captured(String name) {
        final rows = File(
          '../../app/test/features/agents/fixtures/$name.screen',
        ).readAsLinesSync();
        final scan = claude.grid.scanLines;
        return rows.length <= scan ? rows : rows.sublist(rows.length - scan);
      }

      void ask() {
        keeper.track('row-1', agentId: claude.id);
        final asked = hook('PreToolUse', {
          'tool_name': 'AskUserQuestion',
          'tool_use_id': 'toolu_1',
          'tool_input': {
            'questions': [
              {
                'question': 'Pick a colour',
                'header': 'Colour',
                'options': [
                  {'label': 'Red'},
                  {'label': 'Blue'},
                ],
              },
            ],
          },
        });
        expect(asked!.report.hasOpenQuestion, isTrue);
      }

      test('stays open while its menu is drawn, however long', () {
        ask();
        final open = captured('claude-code-question-open');
        for (final wait in const [
          Duration(milliseconds: 500),
          Duration(seconds: 3),
          Duration(minutes: 10),
        ]) {
          clock.now = clock.now.add(wait);
          keeper.screen('row-1', open);
          final now = keeper.statusOf('row-1')!;
          expect(now.report.hasOpenQuestion, isTrue, reason: 'after $wait');
          expect(now.report.hasOpenPrompt, isFalse);
        }
      });

      for (final (left, fixture) in const [
        ('declined with Esc', 'claude-code-question-declined'),
        ('left to "Chat about this"', 'claude-code-question-chat'),
      ]) {
        test('$left, closes once the composer is back, though no hook said '
            'so', () {
          ask();
          clock.now = clock.now.add(const Duration(seconds: 1));
          keeper.screen('row-1', captured('claude-code-question-open'));
          expect(keeper.statusOf('row-1')!.report.hasOpenQuestion, isTrue);

          final back = captured(fixture);
          // Read inside the redraw lag the hook still stands.
          clock.now = clock.now.add(const Duration(milliseconds: 500));
          keeper.screen('row-1', back);
          expect(keeper.statusOf('row-1')!.report.hasOpenQuestion, isTrue);

          clock.now = clock.now.add(const Duration(seconds: 3));
          keeper.screen('row-1', back);
          final closed = keeper.statusOf('row-1')!;
          expect(closed.report.hasOpenQuestion, isFalse);
          expect(closed.report.status, AgentActivityStatus.idle);
          expect(closed.question, isNull);
        });
      }
    });

    test('an approval the screen no longer draws is closed, though no hook '
        'said so', () {
      keeper.track('row-1', agentId: claude.id);
      hook('Notification', {
        'notification_type': 'permission_prompt',
        'message': 'Claude needs your permission to use Bash',
      });
      expect(keeper.statusOf('row-1')!.report.hasOpenPrompt, isTrue);

      clock.now = clock.now.add(const Duration(seconds: 3));
      final closed = keeper.screen(
        'row-1',
        screenOf('claude-code-tui', 0.85, claude),
      );
      expect(closed!.report.hasOpenPrompt, isFalse);
      expect(closed.report.status, AgentActivityStatus.idle);
    });

    test('a stale hook is still the word when the screen says nothing', () {
      keeper.track('row-1', agentId: claude.id);
      final idle = hook('Stop');
      expect(idle!.report.status, AgentActivityStatus.idle);

      // Nobody looks for a while; the screen holds nothing the grid reads.
      clock.now = clock.now.add(const Duration(minutes: 30));
      keeper.screen('row-1', const ['', 'some output the grid cannot read']);
      final kept = keeper.statusOf('row-1')!.report;
      expect(kept.status, AgentActivityStatus.idle);
      expect(kept.source, AgentStatusSource.hook);
      expect(kept.observedAt, clock.now.subtract(const Duration(minutes: 30)));
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
