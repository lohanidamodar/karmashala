import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/presentation/prompt_cards/question_prompt_card.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fixtures.dart';
import 'chat_cards_support.dart';

const _long =
    'A description long enough to wrap over three or four lines on a phone, '
    'so that a card showing all of it for every option would push the rest '
    'of the options and the answers out of sight.';

/// **A question card is compact enough to read on a phone** (the owner's
/// Pixel, 2026-10-07: "this can be more compact? it's hard to view
/// questions"): one slim header, the question clamped, a dense row per
/// option with its description clamped, and one row of actions.
void main() {
  RemoteQuestion overview({bool multiSelect = false}) => RemoteQuestion(
    toolUseId: 'toolu_1',
    questions: [
      RemoteQuestionItem(
        question:
            'Which Overview should the next round build? Each was drawn at '
            'desktop and phone width, and they differ mostly in what the '
            'first screen answers, which is the thing to decide here.',
        header: 'Overview',
        multiSelect: multiSelect,
        options: const [
          RemoteQuestionOption(label: 'A · Strips', description: _long),
          RemoteQuestionOption(
            label: 'B · Cards',
            description: _long,
            preview: '+------+------+\n| card | card |\n+------+------+',
          ),
          RemoteQuestionOption(
            label: 'C · Hybrid (Recommended)',
            description: _long,
          ),
          RemoteQuestionOption(label: 'D · Keep', description: _long),
        ],
      ),
    ],
  );

  final send = find.byKey(const ValueKey('question-send'));
  Finder option(int o) => find.byKey(ValueKey('question-option-0-$o'));
  Finder description(int o) =>
      find.byKey(ValueKey('question-option-desc-0-$o'));
  int? linesOf(WidgetTester tester, int o) =>
      tester.widget<Text>(description(o)).maxLines;
  bool enabled(WidgetTester tester) =>
      tester.widget<FilledButton>(send).onPressed != null;

  late List<({List<RemoteQuestionAnswer> answers, bool decline, bool chat})>
  sent;
  late int terminals;

  Future<void> pump(
    WidgetTester tester, {
    RemoteQuestion? question,
    Size size = const Size(390, 844),
    bool touch = true,
    bool dense = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sent = [];
    terminals = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UiDensityScope(
          density: touch ? UiDensity.touch : UiDensity.pointer,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: QuestionPromptCard(
                agentName: 'Claude Code',
                where: 'in karmashala',
                question: question ?? overview(),
                chatLabel: 'Chat about this',
                dense: dense,
                onAnswerInTerminal: () => terminals++,
                onAnswer: (answers, {decline = false, chat = false}) async =>
                    sent.add((answers: answers, decline: decline, chat: chat)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('answering', () {
    testWidgets('Send is disabled until a choice is made', (tester) async {
      await pump(tester);
      expect(find.descendant(of: send, matching: find.text('Send')), findsOne);
      expect(enabled(tester), isFalse);

      await tester.tap(option(1));
      await tester.pump();
      expect(enabled(tester), isTrue);

      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.single.answers.single.options, [1]);
    });

    testWidgets('Send says what it does as its tooltip, not a line of text', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.text("Your choice is typed into the session's terminal."),
        findsNothing,
      );
      expect(
        find.byTooltip("Your choice is typed into the session's terminal."),
        findsOneWidget,
      );
    });

    testWidgets('"Other…" is the last row and reveals a one-line field', (
      tester,
    ) async {
      await pump(tester);
      final other = find.byKey(const ValueKey('question-option-0-other'));
      expect(
        tester.getTopLeft(other).dy,
        greaterThan(tester.getTopLeft(option(3)).dy),
      );
      final field = find.byKey(const ValueKey('question-other-field-0'));
      expect(field, findsNothing);

      await tester.tap(other);
      await tester.pumpAndSettle();
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).maxLines, 1);
      expect(enabled(tester), isFalse);

      await tester.enterText(field, 'Something else');
      await tester.pump();
      expect(enabled(tester), isTrue);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.single.answers.single.text, 'Something else');
    });

    testWidgets('a multi-select question keeps checkboxes and sends every '
        'option ticked', (tester) async {
      await pump(tester, question: overview(multiSelect: true));
      expect(find.text('Choose any.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('question-option-0-other')),
        findsNothing,
      );
      expect(
        find.descendant(of: option(0), matching: find.byIcon(AppIcons.square)),
        findsOneWidget,
      );

      await tester.tap(option(0));
      await tester.tap(option(2));
      await tester.pump();
      expect(
        find.descendant(of: option(2), matching: find.byIcon(AppIcons.check)),
        findsOneWidget,
      );
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.single.answers.single.options, [0, 2]);
    });
  });

  group('the dense list', () {
    testWidgets('descriptions are clamped to two lines, and the selected one '
        'shows whole', (tester) async {
      await pump(tester);
      for (var o = 0; o < 4; o++) {
        expect(linesOf(tester, o), 2, reason: 'option $o');
      }
      await tester.tap(option(2));
      await tester.pump();
      expect(linesOf(tester, 2), isNull);
      expect(linesOf(tester, 1), 2);
    });

    testWidgets('a chevron, or a long press, opens one description', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('question-option-expand-0-1')),
      );
      await tester.pump();
      expect(linesOf(tester, 1), isNull);
      // Opening it is not choosing it.
      expect(enabled(tester), isFalse);

      await tester.longPress(option(3));
      await tester.pump();
      expect(linesOf(tester, 3), isNull);
      expect(enabled(tester), isFalse);
    });

    testWidgets('"(Recommended)" is a small badge, not part of the label', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('C · Hybrid (Recommended)'), findsNothing);
      expect(
        find.descendant(of: option(2), matching: find.text('C · Hybrid')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: option(2), matching: find.text('Recommended')),
        findsOneWidget,
      );
    });

    testWidgets('rows are at least 44 high on a phone', (tester) async {
      await pump(tester);
      for (var o = 0; o < 4; o++) {
        expect(tester.getSize(option(o)).height, greaterThanOrEqualTo(44));
      }
      expect(
        tester
            .getSize(find.byKey(const ValueKey('question-option-0-other')))
            .height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('a preview is offered under the selected option only, and '
        'opens on request', (tester) async {
      await pump(tester);
      final toggle = find.byKey(const ValueKey('question-preview-toggle-0-1'));
      final preview = find.byKey(const ValueKey('question-preview-0-1'));
      expect(toggle, findsNothing);
      expect(find.textContaining('| card | card |'), findsNothing);

      await tester.tap(option(1));
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      expect(preview, findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(preview, findsOneWidget);
      expect(find.textContaining('| card | card |'), findsOneWidget);
    });

    testWidgets('a long question is clamped to three lines, with "more"', (
      tester,
    ) async {
      await pump(tester, size: const Size(360, 640));
      final text = find.byKey(const ValueKey('question-text-0'));
      expect(tester.widget<Text>(text).maxLines, 3);
      await tester.tap(find.byKey(const ValueKey('question-text-more-0')));
      await tester.pump();
      expect(tester.widget<Text>(text).maxLines, isNull);
    });
  });

  group('the header and actions', () {
    testWidgets('on a phone: one slim header naming the question, the agent '
        'in its tooltip, and Decline, Chat and the terminal in ⋯', (
      tester,
    ) async {
      await pump(tester);
      final header = find.byKey(const ValueKey('question-header'));
      expect(
        find.descendant(of: header, matching: find.text('Overview')),
        findsOneWidget,
      );
      expect(find.textContaining('Claude Code'), findsNothing);
      expect(
        find.byTooltip('Claude Code is asking you a question · in karmashala'),
        findsOneWidget,
      );
      expect(tester.getSize(header).height, lessThanOrEqualTo(Touch.target));

      expect(find.text('Decline'), findsNothing);
      final more = find.byKey(const ValueKey('question-more-actions'));
      for (final (label, check) in [
        ('Answer in the terminal', () => expect(terminals, 1)),
        ('Chat about this', () => expect(sent.last.chat, isTrue)),
        ('Decline', () => expect(sent.last.decline, isTrue)),
      ]) {
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        check();
      }
    });

    testWidgets('on a desktop: the agent beside the header, Decline and Chat '
        'as text buttons, the terminal in ⋯', (tester) async {
      await pump(tester, size: const Size(1440, 900), touch: false);
      // Send keeps the card's far edge, however wide.
      expect(
        tester.getRect(send).right,
        moreOrLessEquals(
          tester.getRect(find.byType(QuestionPromptCard)).right,
          epsilon: 1,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('question-header')),
          matching: find.textContaining('Claude Code'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Decline'));
      await tester.pumpAndSettle();
      expect(sent.single.decline, isTrue);
      expect(
        find.widgetWithText(TextButton, 'Chat about this'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('question-more-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer in the terminal'));
      await tester.pumpAndSettle();
      expect(terminals, 1);
    });

    testWidgets('dense, for a queue: the same answers in less room', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1440, 900),
        touch: false,
        dense: true,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('question-text-0')))
            .maxLines,
        2,
      );
      expect(linesOf(tester, 0), 1);
      // Secondary answers fold into ⋯ however wide.
      expect(find.text('Decline'), findsNothing);
      await tester.tap(option(0));
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(sent.single.answers.single.options, [0]);
    });
  });

  group('in the chat', () {
    const kind = ChatCardSession.terminalCli;
    final inline = find.byKey(const ValueKey('chat-ask:toolu_1'));

    AgentQuestionSet asked() => AgentQuestionSet(
      toolUseId: 'toolu_1',
      questions: [
        AgentQuestion(
          question: overview().questions.single.question,
          header: 'Overview',
          options: [
            for (final o in overview().questions.single.options)
              AgentQuestionOption(
                label: o.label,
                description: o.description,
                preview: o.preview,
              ),
          ],
        ),
      ],
    );

    Future<ChatCardHarness> openChat(
      WidgetTester tester,
      Size size, {
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = await ChatCardHarness.open(
        kind,
        messages: [
          TranscriptMessage(role: 'user', text: 'Plan it.', at: testTime),
          TranscriptMessage(
            role: 'tool',
            text: '',
            tool: const ToolActivity(name: 'AskUserQuestion', subject: 'Which'),
            pendingToolUseId: 'toolu_1',
            at: testTime,
          ),
        ],
        status: ChatCardHarness.statusOf(
          kind,
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.question,
          evidence: const ['Which Overview?'],
        ),
        overrides: [
          sessionAnswerableProvider.overrideWithValue((_) => true),
          transcriptOpenQuestionProvider.overrideWithValue(
            (sessionId, agentId) async => asked(),
          ),
          chatQuestionAnswerProvider.overrideWithValue(
            (_) async => 'Answered.',
          ),
        ],
      );
      addTearDown(h.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: UiDensityScope(
              density: UiDensity.touch,
              child: Scaffold(
                body: SessionTranscriptView(
                  sessionId: 's1',
                  holdForPrompt: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return h;
    }

    bool inside(Rect inner, Rect outer) =>
        inner.top >= outer.top - 0.5 &&
        inner.bottom <= outer.bottom + 0.5 &&
        inner.left >= outer.left - 0.5 &&
        inner.right <= outer.right + 0.5;

    testWidgets('an open question stands in for its tool row, which comes '
        'back once nothing is asked', (tester) async {
      final h = await openChat(tester, const Size(390, 844));
      // No frame or eyebrow around it: the card says all the row would.
      expect(inline, findsOneWidget);
      expect(find.text('Which'), findsNothing);

      h.status(ChatCardHarness.statusOf(kind, AgentActivityStatus.working));
      await tester.pumpAndSettle();
      expect(inline, findsNothing);
      expect(find.text('Which'), findsOneWidget);
    });

    testWidgets('standing in, the card still takes a choice', (tester) async {
      await openChat(tester, const Size(390, 844));
      await tester.tap(option(1));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    });

    for (final size in const [Size(390, 844), Size(360, 640)]) {
      final name = '${size.width.toInt()}×${size.height.toInt()}';
      testWidgets('$name: four long options are all in sight without '
          'scrolling, clamped, and the chosen one opens', (tester) async {
        await openChat(tester, size);
        expect(inline, findsOneWidget);
        final screen = Offset.zero & size;
        final body = tester.getRect(
          find.descendant(
            of: inline,
            matching: find.byKey(const ValueKey('question-options')),
          ),
        );
        for (final row in [
          for (var o = 0; o < 4; o++) option(o),
          find.byKey(const ValueKey('question-option-0-other')),
        ]) {
          final rect = tester.getRect(row);
          expect(inside(rect, body), isTrue, reason: '$row $rect in $body');
          expect(inside(rect, screen), isTrue, reason: '$row $rect on screen');
        }
        for (var o = 0; o < 4; o++) {
          expect(linesOf(tester, o), 2);
        }
        for (final action in [
          send,
          find.byKey(const ValueKey('question-more-actions')),
        ]) {
          expect(inside(tester.getRect(action), screen), isTrue);
        }

        await tester.tap(option(2));
        await tester.pumpAndSettle();
        expect(linesOf(tester, 2), isNull);
        expect(inside(tester.getRect(send), screen), isTrue);
      });
    }

    testWidgets('text scale 1.6 on a phone: nothing clips, and the answers '
        'stay in sight', (tester) async {
      await openChat(tester, const Size(390, 844), textScale: 1.6);
      final error = tester.takeException();
      expect(
        error,
        isNull,
        reason: error is FlutterError ? error.toStringDeep() : '$error',
      );
      final screen = Offset.zero & const Size(390, 844);
      final card = tester.getRect(inline);
      for (final action in [
        send,
        find.byKey(const ValueKey('question-more-actions')),
      ]) {
        final rect = tester.getRect(action);
        expect(inside(rect, screen), isTrue, reason: '$rect');
        expect(inside(rect, card), isTrue, reason: '$rect in $card');
      }
      await tester.tap(option(3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(inside(tester.getRect(send), screen), isTrue);
    });
  });
}
