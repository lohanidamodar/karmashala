import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/prompt_cards/question_prompt_card.dart';
import 'package:karmashala_remote/client.dart' show GatewayException;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/tokens.dart';

/// **A refused answer stays in the card, with why and the way to the
/// terminal** (round 112): a terminal session's typist can refuse many
/// seconds after Send, and a snack bar by then was gone unseen.
void main() {
  const reason =
      'never saw any of its questions on screen, so the answer stopped there '
      '— check the terminal';
  const question = RemoteQuestion(
    toolUseId: 'toolu_1',
    questions: [
      RemoteQuestionItem(
        question: 'सप्तशती पाठ समाप्ति चरण बुकको नवमीमा छैन। राख्ने?',
        header: 'पाठ',
        multiSelect: false,
        ownWords: true,
        options: [
          RemoteQuestionOption(label: 'राख्ने'),
          RemoteQuestionOption(label: 'हटाउने'),
        ],
      ),
    ],
  );

  late int terminals;
  late int sends;

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    bool refuse = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    terminals = 0;
    sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: UiDensityScope(
            density: UiDensity.touch,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: QuestionPromptCard(
                  agentName: 'Claude Code',
                  question: question,
                  onAnswerInTerminal: () => terminals++,
                  onAnswer: (answers, {decline = false, chat = false}) async {
                    sends++;
                    if (refuse && sends == 1) {
                      throw const GatewayException(reason);
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> sendFirstOption(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('question-option-0-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('question-send')));
    await tester.pumpAndSettle();
  }

  for (final (name, size, scale) in [
    ('a 360 px phone at text scale 1.6', const Size(360, 800), 1.6),
    ('a desktop', const Size(1440, 900), 1.0),
  ]) {
    testWidgets('on $name the reason and Answer in the terminal show in the '
        'card', (tester) async {
      await pump(tester, size: size, textScale: scale);
      await sendFirstOption(tester);

      expect(find.textContaining(reason), findsOne);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('question-refusal-terminal')));
      expect(terminals, 1);
    });
  }

  testWidgets('a second Send clears the refusal when it lands', (tester) async {
    await pump(tester, size: const Size(390, 844));
    await sendFirstOption(tester);
    expect(find.byKey(const ValueKey('question-refusal')), findsOne);

    await tester.tap(find.byKey(const ValueKey('question-send')));
    await tester.pumpAndSettle();

    expect(sends, 2);
    expect(find.byKey(const ValueKey('question-refusal')), findsNothing);
  });
}
