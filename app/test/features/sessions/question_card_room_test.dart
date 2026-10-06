import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/application/session_queue_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fixtures.dart';
import 'chat_cards_support.dart';

/// **A question card is always readable and answerable** (the owner's phone,
/// 2026-10-06: "can't scroll or view the complete card"): however tall its
/// options, they scroll inside the card while its answers stay in sight, and
/// the queue below folds to one line to give it the room.
void main() {
  const kind = ChatCardSession.terminalCli;
  const options = 8;

  AgentQuestionSet tall() => AgentQuestionSet(
    toolUseId: 'toolu_1',
    questions: [
      AgentQuestion(
        question: 'How should a webhook start work?',
        header: 'Webhooks',
        options: [
          for (var i = 1; i <= options; i++)
            AgentQuestionOption(
              label: 'Option $i',
              description:
                  'A long description that wraps over several lines on a '
                  'phone, so that eight of them are far taller than the '
                  'room above the composer. Number $i of $options.',
            ),
        ],
      ),
    ],
  );

  QueuedMessage queued(String id, int seq) => QueuedMessage(
    id: id,
    sessionId: 's1',
    seq: seq,
    text: 'queued message $seq',
    state: QueuedMessageState.queued,
    origin: QueuedMessageOrigin.device,
    createdAt: testTime,
    updatedAt: testTime,
  );

  final inline = find.byKey(const ValueKey('chat-ask:toolu_1'));
  late ChatCardHarness harness;

  Future<List<RemoteQuestionAnswerRequest>> open(
    WidgetTester tester, {
    required Size size,
    required bool phone,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sent = <RemoteQuestionAnswerRequest>[];
    final h = await ChatCardHarness.open(
      kind,
      messages: [
        TranscriptMessage(role: 'user', text: 'Plan webhooks.', at: testTime),
        TranscriptMessage(
          role: 'tool',
          text: '',
          tool: const ToolActivity(name: 'AskUserQuestion', subject: 'Hooks'),
          pendingToolUseId: 'toolu_1',
          at: testTime,
        ),
      ],
      status: ChatCardHarness.statusOf(
        kind,
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.question,
        evidence: const ['How should a webhook start work?'],
      ),
      overrides: [
        sessionAnswerableProvider.overrideWithValue((_) => true),
        transcriptOpenQuestionProvider.overrideWithValue(
          (sessionId, agentId) async => tall(),
        ),
        chatQuestionAnswerProvider.overrideWithValue((request) async {
          sent.add(request);
          return 'Answered.';
        }),
        sessionQueueProvider.overrideWith(
          (ref, _) => [queued('q1', 1), queued('q2', 2)],
        ),
      ],
    );
    addTearDown(h.dispose);
    harness = h;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          home: UiDensityScope(
            density: phone ? UiDensity.touch : UiDensity.pointer,
            child: Scaffold(
              body: SessionTranscriptView(
                sessionId: 's1',
                holdForPrompt: phone,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sent;
  }

  Rect rectOf(WidgetTester tester, Finder finder) =>
      tester.getRect(finder.first);

  bool inside(Rect inner, Rect outer) =>
      inner.top >= outer.top - 0.5 &&
      inner.bottom <= outer.bottom + 0.5 &&
      inner.left >= outer.left - 0.5 &&
      inner.right <= outer.right + 0.5;

  for (final (name, size, phone) in [
    ('390×844 phone', const Size(390, 844), true),
    ('360×640 phone', const Size(360, 640), true),
    ('1440×900 desktop', const Size(1440, 900), false),
  ]) {
    testWidgets('$name: every option is reachable inside the card and its '
        'answers stay fully in sight', (tester) async {
      final sent = await open(tester, size: size, phone: phone);
      final screen = Offset.zero & size;

      expect(inline, findsOneWidget);
      final card = rectOf(tester, inline);
      expect(card.height, lessThan(size.height));

      // The answers: pinned at the card's foot, wholly on screen.
      for (final action in ['Decline', 'Chat about this', 'Send answer']) {
        final button = find.descendant(of: inline, matching: find.text(action));
        expect(button, findsOneWidget, reason: action);
        final rect = rectOf(tester, button);
        expect(inside(rect, card), isTrue, reason: '$action $rect in $card');
        expect(inside(rect, screen), isTrue, reason: '$action $rect on screen');
      }

      // The options scroll inside the card, with a visible scrollbar.
      final body = find.descendant(
        of: inline,
        matching: find.byKey(const ValueKey('question-options')),
      );
      expect(body, findsOneWidget);
      expect(
        find.descendant(of: inline, matching: find.byType(Scrollbar)),
        findsOneWidget,
      );
      for (var i = 1; i <= options; i++) {
        final option = find.descendant(
          of: inline,
          matching: find.text('Option $i'),
        );
        await tester.dragUntilVisible(option, body, const Offset(0, -80));
        await tester.pumpAndSettle();
        expect(
          inside(rectOf(tester, option), rectOf(tester, body)),
          isTrue,
          reason: 'Option $i',
        );
      }
      await tester.tap(
        find.descendant(of: inline, matching: find.text('Option $options')),
      );
      await tester.pumpAndSettle();
      final send = find.descendant(
        of: inline,
        matching: find.text('Send answer'),
      );
      expect(inside(rectOf(tester, send), screen), isTrue);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.single.answers.single.options, [options - 1]);
    });

    testWidgets('$name: the queue folds to one line while a question is open', (
      tester,
    ) async {
      await open(tester, size: size, phone: phone);

      expect(find.textContaining('2 queued'), findsOneWidget);
      // Folded: no bubble, so none of its Edit or Cancel.
      expect(find.text('queued message 1'), findsNothing);
      expect(find.text('Edit'), findsNothing);
    });
  }

  testWidgets('a question answered on another client clears on the phone in '
      'the same update: the card goes, the box takes a message, the queue '
      'unfolds', (tester) async {
    await open(tester, size: const Size(390, 844), phone: true);
    expect(inline, findsOneWidget);
    expect(find.text('Answer the prompt above first'), findsOneWidget);

    harness.status(ChatCardHarness.statusOf(kind, AgentActivityStatus.working));
    await tester.pump();
    await tester.pump();

    expect(inline, findsNothing);
    expect(find.text('Answer the prompt above first'), findsNothing);
    expect(find.text('Message the agent…'), findsOneWidget);
    expect(find.text('queued message 1'), findsOneWidget);
  });
}
