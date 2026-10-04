import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_turn_interrupt.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import '../../support/fixtures.dart';
import 'chat_cards_support.dart';

const _plan = '## Plan\n\n1. Read the parser\n2. Fix the off-by-one';

/// **An agent leaving plan mode asks in the chat**: the plan as a card with
/// Approve plan / Keep planning / Stop, each answered the way the agent's
/// descriptor says its prompt is answered.
void main() {
  for (final kind in ChatCardSession.values) {
    group('${kind.name}:', () {
      // What each face calls the call that asks: Claude Code's own tool, and
      // the stream-json bridge's title for it — told apart by kind, not title.
      final toolName = switch (kind) {
        ChatCardSession.terminalCli => 'ExitPlanMode',
        ChatCardSession.acp => 'Ready to code?',
      };

      List<TranscriptMessage> turn() => [
        TranscriptMessage(role: 'user', text: 'Plan the fix.', at: testTime),
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: ToolActivity(name: toolName),
          pendingToolUseId: 'plan-1',
          at: testTime,
        ),
      ];

      final asking = ChatCardHarness.statusOf(
        kind,
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
        evidence: [toolName],
        toolAsk: AgentToolAsk(
          toolName: toolName,
          input: const {'plan': _plan},
          at: testTime,
          toolUseId: 'plan-1',
          kind: kind == ChatCardSession.acp ? 'switch_mode' : null,
        ),
      );

      /// Claude Code 2.1.287's prompt as its screen draws it: a clear-context
      /// yes, the mode yeses, and the optional Ultraplan row ahead of keep
      /// planning.
      const screenMenu = AgentScreenMenu(
        prompt: ['Would you like to proceed?'],
        options: [
          'Yes, clear context (31% used) and use auto mode',
          'Yes, and use auto mode',
          'Yes, auto-accept edits',
          'Yes, manually approve edits',
          'No, refine with Ultraplan in a cloud session',
          'No, keep planning',
        ],
        highlighted: 0,
      );

      Future<(ChatCardHarness, RecordingPromptAnswers, List<String>)> open(
        WidgetTester tester, {
        String? permissionMode,
        bool menuReadable = true,
      }) async {
        late final ChatCardHarness h;
        final interrupts = <String>[];
        final answers = RecordingPromptAnswers(
          menu: kind == ChatCardSession.terminalCli && menuReadable
              ? screenMenu
              : null,
          onAnswer: (_) => h.status(
            ChatCardHarness.statusOf(kind, AgentActivityStatus.working),
          ),
        );
        h = await ChatCardHarness.open(
          kind,
          messages: turn(),
          status: asking,
          permissionMode: permissionMode,
          overrides: [
            sessionPromptAnswersProvider.overrideWithValue(answers),
            sessionAnswerableProvider.overrideWithValue((_) => true),
            sessionTurnInterruptProvider.overrideWithValue((id) async {
              interrupts.add(id);
              h.status(ChatCardHarness.idle(kind));
              return null;
            }),
          ],
        );
        addTearDown(h.dispose);
        await tester.pumpWidget(chatWithDock(h.container));
        await tester.pumpAndSettle();
        return (h, answers, interrupts);
      }

      final card = find.byKey(const ValueKey('plan-approval:plan-1'));

      testWidgets('the plan is a card under its call, and the dock steps '
          'aside', (tester) async {
        await open(tester);

        expect(card, findsOneWidget);
        expect(
          find.descendant(
            of: card,
            matching: find.textContaining('Fix the off-by-one'),
          ),
          findsOneWidget,
        );
        for (final label in ['Approve plan', 'Keep planning', 'Stop']) {
          expect(
            find.descendant(of: card, matching: find.text(label)),
            findsOneWidget,
          );
        }
        // The dock's generic answers are not on screen as well.
        expect(find.byKey(const ValueKey('dock-allow-once')), findsNothing);
      });

      if (kind == ChatCardSession.acp) {
        // The server picks the allow at or below the session's rung
        // (acp_plan_permission_test.dart).
        testWidgets('Approve plan is the request\'s approve', (tester) async {
          final (_, answers, _) = await open(tester);

          await tester.tap(find.text('Approve plan'));
          await tester.pumpAndSettle();

          final answer = answers.answers.single as ApprovalAnswerRequest;
          expect(answer.approve, isTrue);
          expect(answer.ask?.toolUseId, 'plan-1');
          expect(card, findsNothing);
        });
      } else {
        for (final (mode, chosen) in [
          (null, 'Yes, manually approve edits'),
          ('mode=manual', 'Yes, manually approve edits'),
          ('mode=acceptEdits', 'Yes, auto-accept edits'),
          // No bypass row here: auto mode is the highest at or below it.
          ('mode=bypassPermissions', 'Yes, and use auto mode'),
          // Approving a plan leaves read-only; asking is the floor.
          ('mode=plan', 'Yes, manually approve edits'),
        ]) {
          testWidgets('Approve plan at ${mode ?? 'the default'} never raises '
              'the session: "$chosen"', (tester) async {
            final (_, answers, _) = await open(tester, permissionMode: mode);

            await tester.tap(find.text('Approve plan'));
            await tester.pumpAndSettle();

            final answer = answers.answers.single as MenuAnswerRequest;
            expect(answer.menuId, screenMenu.id);
            expect(screenMenu.options[answer.option], chosen);
            expect(card, findsNothing);
          });
        }

        testWidgets('Approve plan sends nothing when the prompt cannot be '
            'read', (tester) async {
          final (_, answers, _) = await open(tester, menuReadable: false);

          await tester.tap(find.text('Approve plan'));
          await tester.pumpAndSettle();

          expect(answers.answers, isEmpty);
          expect(find.textContaining('nothing was sent'), findsOneWidget);
          expect(card, findsOneWidget);
        });
      }

      testWidgets('Keep planning picks the agent\'s own keep-planning answer', (
        tester,
      ) async {
        final (_, answers, _) = await open(tester);

        await tester.tap(find.text('Keep planning'));
        await tester.pumpAndSettle();

        final answer = answers.answers.single;
        switch (kind) {
          // By its words: Claude Code's first "No" can be Ultraplan's.
          case ChatCardSession.terminalCli:
            answer as MenuAnswerRequest;
            expect(answer.menuId, screenMenu.id);
            expect(
              answer.option,
              screenMenu.options.indexOf('No, keep planning'),
            );
          // The request's reject is "No, keep planning".
          case ChatCardSession.acp:
            answer as ApprovalAnswerRequest;
            expect(answer.approve, isFalse);
            expect(answer.ask?.toolUseId, 'plan-1');
        }
        expect(card, findsNothing);
      });

      testWidgets('Stop stops the turn the way the Stop button does', (
        tester,
      ) async {
        final (_, answers, interrupts) = await open(tester);

        await tester.tap(find.text('Stop'));
        await tester.pumpAndSettle();

        expect(interrupts, ['s1']);
        expect(answers.answers, isEmpty);
        expect(card, findsNothing);
      });
    });
  }

  testWidgets(
    'a tool the descriptor does not name stays an ordinary approval',
    (tester) async {
      final h = await ChatCardHarness.open(
        ChatCardSession.terminalCli,
        messages: [
          TranscriptMessage(
            role: 'tool',
            text: '',
            tool: const ToolActivity(name: 'Bash', subject: 'make plan'),
            pendingToolUseId: 'call-1',
            at: testTime,
          ),
        ],
        status: ChatCardHarness.statusOf(
          ChatCardSession.terminalCli,
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
          toolAsk: AgentToolAsk(
            toolName: 'Bash',
            input: const {'command': 'make plan', 'plan': 'not one'},
            at: testTime,
            toolUseId: 'call-1',
          ),
        ),
        overrides: [sessionAnswerableProvider.overrideWithValue((_) => true)],
      );
      addTearDown(h.dispose);
      await tester.pumpWidget(chatWithDock(h.container));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('plan-approval:call-1')), findsNothing);
      expect(find.byKey(const ValueKey('chat-ask:call-1')), findsOneWidget);
    },
  );

  /// An ACP session asking about one switch_mode call, titled [title].
  Future<void> acpAsk(
    WidgetTester tester, {
    required String title,
    required Map<String, Object?> input,
  }) async {
    final h = await ChatCardHarness.open(
      ChatCardSession.acp,
      messages: [
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: ToolActivity(name: title),
          pendingToolUseId: 'mode-1',
          at: testTime,
        ),
      ],
      status: ChatCardHarness.statusOf(
        ChatCardSession.acp,
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
        toolAsk: AgentToolAsk(
          toolName: title,
          input: input,
          at: testTime,
          toolUseId: 'mode-1',
          kind: 'switch_mode',
        ),
      ),
      overrides: [sessionAnswerableProvider.overrideWithValue((_) => true)],
    );
    addTearDown(h.dispose);
    await tester.pumpWidget(chatWithDock(h.container));
    await tester.pumpAndSettle();
  }

  testWidgets('the claude-agent-acp adapter\'s title is a plan prompt too: '
      'the kind decides', (tester) async {
    await acpAsk(tester, title: 'Approve Plan', input: const {'plan': _plan});
    expect(find.byKey(const ValueKey('plan-approval:mode-1')), findsOneWidget);
  });

  testWidgets('a switch_mode ask with no plan (entering plan mode) is an '
      'ordinary approval', (tester) async {
    await acpAsk(tester, title: 'Enter plan mode', input: const {});
    expect(find.byKey(const ValueKey('plan-approval:mode-1')), findsNothing);
    expect(find.byKey(const ValueKey('chat-ask:mode-1')), findsOneWidget);
  });
}
