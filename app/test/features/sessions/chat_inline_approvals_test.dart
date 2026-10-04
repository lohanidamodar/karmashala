import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import '../../support/fixtures.dart';
import 'chat_cards_support.dart';

/// **A pending approval is answered where its call is in the chat**, with the
/// dock's own answers, and the dock steps aside while the chat shows it.
void main() {
  for (final kind in ChatCardSession.values) {
    group('${kind.name}:', () {
      List<TranscriptMessage> turn() => [
        TranscriptMessage(role: 'user', text: 'Clean the build.', at: testTime),
        TranscriptMessage(
          role: 'agent',
          text: 'Removing the build folder.',
          at: testTime,
        ),
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: const ToolActivity(name: 'Bash', subject: 'rm -rf build'),
          pendingToolUseId: 'call-1',
          at: testTime,
        ),
      ];

      AgentStatusReport asking(String toolUseId) => ChatCardHarness.statusOf(
        kind,
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
        evidence: const ['Bash'],
        toolAsk: AgentToolAsk(
          toolName: 'Bash',
          input: const {'command': 'rm -rf build'},
          at: testTime,
          toolUseId: toolUseId,
        ),
      );

      Future<(ChatCardHarness, RecordingPromptAnswers)> open(
        WidgetTester tester, {
        required String askedAbout,
      }) async {
        late final ChatCardHarness h;
        final answers = RecordingPromptAnswers(
          // The agent takes the answer and goes back to work.
          onAnswer: (_) => h.status(
            ChatCardHarness.statusOf(kind, AgentActivityStatus.working),
          ),
        );
        h = await ChatCardHarness.open(
          kind,
          messages: turn(),
          status: asking(askedAbout),
          overrides: [
            sessionPromptAnswersProvider.overrideWithValue(answers),
            sessionAnswerableProvider.overrideWithValue((_) => true),
          ],
        );
        addTearDown(h.dispose);
        await tester.pumpWidget(chatWithDock(h.container));
        await tester.pumpAndSettle();
        return (h, answers);
      }

      final allowOnce = find.byKey(const ValueKey('dock-allow-once'));
      final inline = find.byKey(const ValueKey('chat-ask:call-1'));

      testWidgets('the ask is drawn under its call, and the dock steps aside', (
        tester,
      ) async {
        await open(tester, askedAbout: 'call-1');

        expect(inline, findsOneWidget);
        // One set of answers on screen: the chat's.
        expect(allowOnce, findsOneWidget);
        expect(
          find.descendant(of: inline, matching: allowOnce),
          findsOneWidget,
        );
      });

      testWidgets('answering in the chat answers once and clears both', (
        tester,
      ) async {
        final (_, answers) = await open(tester, askedAbout: 'call-1');

        await tester.tap(find.descendant(of: inline, matching: allowOnce));
        await tester.pumpAndSettle();

        expect(answers.answers, hasLength(1));
        final answer = answers.answers.single as ApprovalAnswerRequest;
        expect(answer.approve, isTrue);
        expect(answer.ask?.toolUseId, 'call-1');
        expect(inline, findsNothing);
        expect(allowOnce, findsNothing);
      });

      testWidgets('an ask about a call the chat does not hold stays in the '
          'dock', (tester) async {
        await open(tester, askedAbout: 'call-elsewhere');

        expect(find.byKey(const ValueKey('chat-ask:call-elsewhere')), findsNothing);
        expect(inline, findsNothing);
        expect(allowOnce, findsOneWidget);
      });
    });
  }
}
