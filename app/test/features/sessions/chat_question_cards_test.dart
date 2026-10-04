import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show HostSessionState;

import '../../support/fake_host_lifecycle.dart';

import '../../support/fixtures.dart';
import 'chat_cards_support.dart';

/// **A CLI's multiple-choice question is answered from the chat view**, in the
/// dock and under the call that asks it (the owner's report, 2026-10-04: "I
/// was unable to reply to multiple-choice or single-choice CLI questions from
/// the chat view").
void main() {
  const kind = ChatCardSession.terminalCli;

  AgentQuestionSet fruit({bool multiSelect = false}) => AgentQuestionSet(
    toolUseId: 'toolu_1',
    questions: [
      AgentQuestion(
        question: 'Pick a fruit',
        header: 'Fruit',
        multiSelect: multiSelect,
        options: const [
          AgentQuestionOption(label: 'Apple'),
          AgentQuestionOption(label: 'Banana'),
        ],
      ),
    ],
  );

  final asking = ChatCardHarness.statusOf(
    kind,
    AgentActivityStatus.awaitingApproval,
    waiting: AgentWaitKind.question,
    evidence: const ['Pick a fruit'],
  );

  Future<(ChatCardHarness, List<RemoteQuestionAnswerRequest>)> open(
    WidgetTester tester, {
    required List<TranscriptMessage> messages,
    required Future<AgentQuestionSet?> Function() question,
    bool hostRuns = false,
  }) async {
    late final ChatCardHarness h;
    final sent = <RemoteQuestionAnswerRequest>[];
    h = await ChatCardHarness.open(
      kind,
      messages: messages,
      status: asking,
      overrides: [
        sessionAnswerableProvider.overrideWithValue((_) => true),
        if (hostRuns)
          hostLifecycleSourceProvider.overrideWithValue(
            FakeHostLifecycle()
              ..snapshot = [hostFacts('s1', HostSessionState.running)],
          ),
        transcriptOpenQuestionProvider.overrideWithValue(
          (sessionId, agentId) => question(),
        ),
        chatQuestionAnswerProvider.overrideWithValue((request) async {
          sent.add(request);
          h.status(ChatCardHarness.statusOf(kind, AgentActivityStatus.working));
          return 'Answered.';
        }),
      ],
    );
    addTearDown(h.dispose);
    if (hostRuns) {
      // The host runs the session and kept no question: no hook carried one.
      h.container.listen(hostLifecycleSubscriberProvider, (_, _) {});
      h.container.read(hostLifecycleSubscriberProvider)!.nudge();
      await tester.pump();
      expect(
        h.container.read(hostLifecycleSubscriberProvider)!.knows('s1'),
        isTrue,
      );
    }
    await tester.pumpWidget(chatWithDock(h.container));
    await tester.pumpAndSettle();
    return (h, sent);
  }

  List<TranscriptMessage> askingTurn() => [
    TranscriptMessage(role: 'user', text: 'Make a salad.', at: testTime),
    TranscriptMessage(
      role: 'tool',
      text: '',
      tool: const ToolActivity(name: 'AskUserQuestion', subject: 'Fruit'),
      pendingToolUseId: 'toolu_1',
      at: testTime,
    ),
  ];

  testWidgets('a question that is readable only after its status arrived '
      'still gets its options', (tester) async {
    // The hook says a question is open before the agent's record holds it.
    var written = false;
    await open(
      tester,
      messages: [
        TranscriptMessage(role: 'user', text: 'Make a salad.', at: testTime),
      ],
      question: () async => written ? fruit() : null,
    );
    expect(find.text('Send answer'), findsNothing);

    written = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Banana'), findsOneWidget);
    expect(find.text('Send answer'), findsOneWidget);
  });

  final inline = find.byKey(const ValueKey('chat-ask:toolu_1'));

  testWidgets('a single-choice question is answered once under its call', (
    tester,
  ) async {
    final (_, sent) = await open(
      tester,
      messages: askingTurn(),
      question: () async => fruit(),
    );

    expect(inline, findsOneWidget);
    // One form on screen: the chat's, not the dock's as well.
    expect(find.text('Send answer'), findsOneWidget);
    await tester.tap(
      find.descendant(of: inline, matching: find.text('Banana')),
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: inline, matching: find.text('Send answer')),
    );
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(sent.single.toolUseId, 'toolu_1');
    expect(sent.single.answers.single.options, [1]);
    expect(inline, findsNothing);
    expect(find.text('Send answer'), findsNothing);
  });

  testWidgets('a multi-select question sends every option ticked', (
    tester,
  ) async {
    final (_, sent) = await open(
      tester,
      messages: askingTurn(),
      question: () async => fruit(multiSelect: true),
    );

    for (final label in ['Apple', 'Banana']) {
      await tester.tap(find.descendant(of: inline, matching: find.text(label)));
      await tester.pump();
    }
    await tester.tap(
      find.descendant(of: inline, matching: find.text('Send answer')),
    );
    await tester.pumpAndSettle();

    expect(sent.single.answers.single.options, [0, 1]);
    expect(inline, findsNothing);
  });

  testWidgets('a session the host runs, whose host kept no question from a '
      'hook, still gets it from the agent\'s record', (tester) async {
    await open(
      tester,
      messages: askingTurn(),
      question: () async => fruit(),
      hostRuns: true,
    );

    expect(inline, findsOneWidget);
    expect(find.text('Banana'), findsOneWidget);
    expect(find.text('Send answer'), findsOneWidget);
  });

  testWidgets('"Chat about this" is its own action, sent as such', (
    tester,
  ) async {
    final (_, sent) = await open(
      tester,
      messages: askingTurn(),
      question: () async => fruit(),
    );

    await tester.tap(
      find.descendant(of: inline, matching: find.text('Chat about this')),
    );
    await tester.pumpAndSettle();

    expect(sent.single.chat, isTrue);
    expect(sent.single.toolUseId, 'toolu_1');
    expect(sent.single.answers, isEmpty);
    expect(inline, findsNothing);
  });
}
