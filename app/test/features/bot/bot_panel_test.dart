import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/bot/presentation/bot_panel.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/tokens.dart';

import 'bot_support.dart';

Future<void> pumpPanel(
  WidgetTester tester,
  ProviderContainer container, {
  double scale = 1,
  bool phone = false,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: LayoutBuilder(
              builder: (context, box) => SizedBox(
                width: box.maxWidth < Chrome.botPanelWidth
                    ? box.maxWidth
                    : Chrome.botPanelWidth,
                child: BotPanelView(phone: phone, onClose: onClose ?? () {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A card scrolls within its strip: brought into view as a person would.
Future<void> tapCard(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

void main() {
  late BotRig rig;

  setUp(() => rig = BotRig());

  group('states', () {
    testWidgets('empty: what it does, samples, and nothing made', (
      tester,
    ) async {
      final container = await rig.container();
      await pumpPanel(tester, container);

      expect(find.byKey(const ValueKey('bot-empty')), findsOneWidget);
      expect(find.byType(SessionTranscriptView), findsNothing);
      expect(rig.bot.asked.whereType<BotOpen>(), isEmpty);

      await tester.tap(find.text('What is waiting for me?'));
      await tester.pump();
      final box = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('bot-first-message')),
          matching: find.byType(TextField),
        ),
      );
      expect(box.controller?.text, 'What is waiting for me?');
      expect(rig.server.sessionWork.sent, isEmpty, reason: 'filled, not sent');
    });

    testWidgets('the first message opens the conversation', (tester) async {
      final container = await rig.container();
      await pumpPanel(tester, container);

      await tester.enterText(find.byType(TextField), 'resume my work');
      await tester.tap(find.byTooltip(RegExp('^Send')));
      await tester.pumpAndSettle();

      expect(rig.server.sessionWork.sent.single.text, 'resume my work');
      expect(find.byType(SessionTranscriptView), findsOneWidget);
    });

    testWidgets('a first message refused keeps its words and says why', (
      tester,
    ) async {
      rig.bot.openRefusal = const DataRefused.unavailable(
        'no agent can run the bot',
      );
      final container = await rig.container();
      await pumpPanel(tester, container);

      await tester.enterText(find.byType(TextField), 'resume my work');
      await tester.tap(find.byTooltip(RegExp('^Send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('composer-send-error')), findsOneWidget);
      expect(find.text('resume my work'), findsOneWidget);
      expect(find.byType(SessionTranscriptView), findsNothing);
    });

    testWidgets('no agent: the reason, and the way to Agents', (tester) async {
      rig.bot.agents = const [];
      final container = await rig.container();
      await pumpPanel(tester, container);

      expect(
        find.textContaining('No agent the bot can run on'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bot-open-agents')), findsOneWidget);
      expect(find.byKey(const ValueKey('bot-first-message')), findsNothing);
    });

    testWidgets('a notice is shown as the server says it', (tester) async {
      rig.bot.notice = 'The default agent has no chat form, so Claude runs it.';
      final container = await rig.container();
      await pumpPanel(tester, container);
      expect(find.text(rig.bot.notice!), findsOneWidget);
    });

    testWidgets('a row cleared elsewhere goes back to the empty state, '
        'draft kept', (tester) async {
      final row = botRow(rig);
      final container = await rig.container();
      await pumpPanel(tester, container);
      expect(find.byType(SessionTranscriptView), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'half typed');

      rig.bot.rowMoved(row.copyWith(archivedAt: DateTime.utc(2026, 11, 3)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('bot-empty')), findsOneWidget);
      expect(find.text('half typed'), findsOneWidget);
    });
  });

  group('the conversation', () {
    testWidgets('offers no fork, rewind or Switch agent of its own', (
      tester,
    ) async {
      botRow(rig);
      final container = await rig.container();
      await pumpPanel(tester, container);

      expect(find.byKey(const ValueKey('switch-agent')), findsNothing);
      expect(find.byKey(const ValueKey('bot-agent-switcher')), findsOneWidget);
    });
  });

  group('approvals', () {
    testWidgets('Yes answers, and the exact call can be read first', (
      tester,
    ) async {
      botRow(rig);
      rig.bot.approvals.add(approvalOf('a'));
      final container = await rig.container();
      await pumpPanel(tester, container);

      expect(find.text('Remove the worktree x'), findsOneWidget);
      await tapCard(tester, 'bot-approval-show:a');
      await tester.pump();
      expect(find.textContaining('worktree_remove'), findsOneWidget);

      await tapCard(tester, 'bot-approve:a');
      await tester.pumpAndSettle();
      expect(
        rig.bot.asked.whereType<BotApprovalAnswer>().single.approve,
        isTrue,
      );
      expect(find.text('Remove the worktree x'), findsNothing);
    });

    testWidgets('No answers no', (tester) async {
      botRow(rig);
      rig.bot.approvals.add(approvalOf('a'));
      final container = await rig.container();
      await pumpPanel(tester, container);
      await tapCard(tester, 'bot-deny:a');
      await tester.pumpAndSettle();
      expect(
        rig.bot.asked.whereType<BotApprovalAnswer>().single.approve,
        isFalse,
      );
    });

    testWidgets('already answered says so and does not fail silently', (
      tester,
    ) async {
      botRow(rig);
      rig.bot
        ..approvals.add(approvalOf('a'))
        ..answerRefusal = DataRefused(
          DataRefusalCode.conflict,
          'That was already answered.',
        );
      final container = await rig.container();
      await pumpPanel(tester, container);
      await tapCard(tester, 'bot-approve:a');
      await tester.pumpAndSettle();
      expect(find.text('That was already answered.'), findsOneWidget);
    });

    testWidgets('nothing it says calls the bot safe or sandboxed', (
      tester,
    ) async {
      botRow(rig);
      rig.bot.approvals.add(approvalOf('a'));
      final container = await rig.container();
      await pumpPanel(tester, container);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final words = (text.data ?? '').toLowerCase();
        expect(words, isNot(contains('safe')));
        expect(words, isNot(contains('sandbox')));
      }
    });
  });

  group('the header', () {
    testWidgets('Clear asks first, then clears', (tester) async {
      botRow(rig);
      final container = await rig.container();
      await pumpPanel(tester, container);

      await tester.tap(find.byKey(const ValueKey('bot-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear conversation…'));
      await tester.pumpAndSettle();
      expect(rig.bot.asked.whereType<BotClear>(), isEmpty);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(rig.bot.asked.whereType<BotClear>(), hasLength(1));
      expect(find.byKey(const ValueKey('bot-empty')), findsOneWidget);
    });

    testWidgets('mid-turn the switcher says why and does nothing', (
      tester,
    ) async {
      botRow(rig);
      final container = await rig.container();
      rig.server.attention.statusOf('bot-1', AgentActivityStatus.working);
      await pumpPanel(tester, container);

      await tester.tap(find.byKey(const ValueKey('bot-agent-switcher')));
      await tester.pump();
      expect(find.text('Default agent'), findsNothing);
      expect(find.textContaining('wait for it to end'), findsOneWidget);
      expect(rig.bot.asked.whereType<BotAgentSet>(), isEmpty);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a pick switches with one call', (tester) async {
      botRow(rig);
      final container = await rig.container();
      await pumpPanel(tester, container);

      await tester.tap(find.byKey(const ValueKey('bot-agent-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();
      expect(
        rig.bot.asked.whereType<BotAgentSet>().single.agentId,
        'codex-acp',
      );
      expect(find.text('Codex'), findsOneWidget);
    });

    testWidgets('every control has a name', (tester) async {
      botRow(rig);
      final container = await rig.container();
      final handle = tester.ensureSemantics();
      await pumpPanel(tester, container);
      expect(find.bySemanticsLabel(RegExp('Agent: Claude')), findsOneWidget);
      expect(find.byTooltip('Close the bot'), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);
      handle.dispose();
    });
  });

  group('no overflow', () {
    for (final (name, size, scale) in panelMatrix) {
      testWidgets('empty at $name', (tester) async {
        sizeWindow(tester, size);
        final container = await rig.container();
        await pumpPanel(
          tester,
          container,
          scale: scale,
          phone: size.width < 600,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('with approvals at $name', (tester) async {
        sizeWindow(tester, size);
        botRow(rig);
        rig.bot.approvals
          ..add(approvalOf('a'))
          ..add(
            approvalOf(
              'b',
              summary:
                  'End the session named Fix the very long login redirect '
                  'that nobody could read in one line of a phone',
            ),
          );
        final container = await rig.container();
        await pumpPanel(
          tester,
          container,
          scale: scale,
          phone: size.width < 600,
        );
        expect(tester.takeException(), isNull);
        await tapCard(tester, 'bot-approve:b');
        await tester.pumpAndSettle();
        expect(rig.bot.asked.whereType<BotApprovalAnswer>().single.id, 'b');
      });

      testWidgets('no agent at $name', (tester) async {
        sizeWindow(tester, size);
        rig.bot.agents = const [];
        final container = await rig.container();
        await pumpPanel(tester, container, scale: scale);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
