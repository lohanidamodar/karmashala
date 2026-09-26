/// An agent's multiple-choice question on the phone: its options to tap, its
/// own-words box, several questions at once, a decline — and never the
/// Approve button, which would answer with whatever option is highlighted.
library;

import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  const fruit = RemoteQuestionItem(
    question: 'Pick a fruit',
    header: 'Fruit',
    options: [
      RemoteQuestionOption(label: 'Apple', description: 'Crisp'),
      RemoteQuestionOption(label: 'Banana'),
      RemoteQuestionOption(label: 'Cherry'),
    ],
  );
  const colours = RemoteQuestionItem(
    question: 'Pick colours',
    header: 'Colours',
    multiSelect: true,
    options: [
      RemoteQuestionOption(label: 'Red'),
      RemoteQuestionOption(label: 'Green'),
      RemoteQuestionOption(label: 'Blue'),
    ],
  );

  CompanionApproval asking(List<RemoteQuestionItem> questions) =>
      CompanionApproval(
        id: 'a1',
        sessionId: 's1',
        agentName: 'Claude Code',
        waiting: RemoteWaitKind.question,
        evidence: [for (final q in questions) q.question],
        question: RemoteQuestion(toolUseId: 't1', questions: questions),
      );

  late List<({List<RemoteQuestionAnswer> answers, bool decline})> sent;
  setUp(() => sent = []);

  Future<void> pump(WidgetTester tester, CompanionApproval approval) =>
      pumpPhone(
        tester,
        gateway: FakeCompanionGateway.paired(),
        home: Scaffold(
          body: CompanionApprovalCard(
            approval: approval,
            onAnswer: (_) async => fail('a question is never approved'),
            onAnswerQuestion: (answers, {decline = false}) async =>
                sent.add((answers: answers, decline: decline)),
          ),
        ),
      );

  Future<void> send(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Send answer'));
    await tester.pumpAndSettle();
  }

  testWidgets('one question: its options, and no Approve anywhere', (
    tester,
  ) async {
    await pump(tester, asking([fruit]));

    expect(find.text('Pick a fruit'), findsWidgets);
    expect(find.text('Apple'), findsOneWidget);
    expect(find.text('Crisp'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);

    await tester.tap(find.text('Banana'));
    await tester.pumpAndSettle();
    await send(tester);

    expect(sent.single.decline, isFalse);
    expect(sent.single.answers.single.options, [1]);
  });

  testWidgets('nothing is sent until every question has an answer', (
    tester,
  ) async {
    await pump(tester, asking([fruit, colours]));
    final button = find.widgetWithText(FilledButton, 'Send answer');

    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.tap(find.text('Cherry'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.ensureVisible(find.text('Blue'));
    await tester.tap(find.text('Red'));
    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(button);
    await send(tester);

    expect(sent.single.answers[0].options, [2]);
    expect(sent.single.answers[1].options, [0, 2]);
  });

  testWidgets('own words, through Other', (tester) async {
    await pump(tester, asking([fruit]));

    await tester.tap(find.text('Other…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Durian');
    await tester.pumpAndSettle();
    await send(tester);

    expect(sent.single.answers.single.text, 'Durian');
  });

  testWidgets('a multi-choice question offers no own-words box', (
    tester,
  ) async {
    await pump(tester, asking([colours]));
    expect(find.text('Other…'), findsNothing);
  });

  testWidgets('Decline says no without choosing', (tester) async {
    await pump(tester, asking([fruit]));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Decline'));
    await tester.pumpAndSettle();

    expect(sent.single.decline, isTrue);
    expect(sent.single.answers, isEmpty);
  });

  testWidgets('a question the host could not read points at the desktop', (
    tester,
  ) async {
    await pump(
      tester,
      const CompanionApproval(
        id: 'a1',
        sessionId: 's1',
        agentName: 'Claude Code',
        waiting: RemoteWaitKind.question,
      ),
    );

    expect(find.textContaining('could not read'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Approve'), findsNothing);
  });
}
