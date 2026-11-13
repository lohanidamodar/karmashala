import 'package:agent_cli/read.dart'
    show
        QueuedState,
        TranscriptMessage,
        kTranscriptCommandRole,
        kTranscriptNoticeRole;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_inline_images.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart'
    show chatMessagesFromTranscript;

/// Rows the agents write besides turns and calls, as the chat draws them.
void main() {
  Widget view(List<ChatMessage> messages) => MaterialApp(
    home: Scaffold(body: ChatTranscriptView(messages: messages)),
  );

  testWidgets('a notice is a small note, not a card in the agent\'s name', (
    tester,
  ) async {
    await tester.pumpWidget(
      view([
        const ChatMessage(role: 'agent', text: 'Running it.'),
        const ChatMessage(
          role: kTranscriptNoticeRole,
          text: 'PreToolUse:Bash hook blocked it: rm is not allowed',
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('PreToolUse:Bash hook blocked it: rm is not allowed'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('transcript-notice')), findsOneWidget);
    expect(find.text('AGENT'), findsNothing);
    expect(find.text('Agent'), findsNothing);
  });

  testWidgets('a command the person ran is its own card, never folded', (
    tester,
  ) async {
    ChatMessage read(String file) => ChatMessage(
      role: 'tool',
      text: 'Read($file)',
      tool: ToolActivity(name: 'Read', subject: file, output: 'ok'),
    );
    await tester.pumpWidget(
      view([
        read('a.dart'),
        const ChatMessage(
          role: kTranscriptCommandRole,
          text: '/model opus',
          tool: ToolActivity(
            name: '/model',
            subject: 'opus',
            output: 'Set model to opus',
          ),
        ),
        read('b.dart'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(RegExp('/model', caseSensitive: false)),
      findsWidgets,
    );
    expect(
      find.textContaining('Set model to opus', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('<command-name>'), findsNothing);
  });

  test('a subagent\'s own calls are not drawn at the top level', () {
    final chat = chatMessagesFromTranscript(const [
      TranscriptMessage(
        role: 'tool',
        text: 'Agent(List files)',
        tool: ToolActivity(name: 'Agent', subject: 'List files'),
      ),
      TranscriptMessage(
        role: 'tool',
        text: 'Bash(ls)',
        tool: ToolActivity(name: 'Bash', subject: 'ls'),
        parentToolUseId: 'ag',
      ),
      TranscriptMessage(role: 'agent', text: 'Done.'),
    ]);

    expect(chat.map((m) => m.text), ['Agent(List files)', 'Done.']);
  });

  testWidgets('a prompt sent while the agent worked is marked so', (
    tester,
  ) async {
    final chat = chatMessagesFromTranscript(const [
      TranscriptMessage(role: 'user', text: 'Run the tests'),
      TranscriptMessage(role: 'user', text: 'Also, what is 2+2?', queued: true),
    ]);
    expect(chat.map((m) => m.queued), [false, true]);

    await tester.pumpWidget(view(chat));
    await tester.pumpAndSettle();

    expect(find.text('Sent while working'), findsOneWidget);
    expect(
      find.textContaining('Also, what is 2+2?', findRichText: true),
      findsOneWidget,
    );
  });

  group('a message in Claude Code\'s own queue', () {
    testWidgets('while it waits, it shows once, marked Queued', (tester) async {
      final chat = chatMessagesFromTranscript(const [
        TranscriptMessage(role: 'user', text: 'Run the tests'),
        TranscriptMessage(
          role: 'user',
          text: 'And the docs',
          queueState: QueuedState.waiting,
        ),
      ]);
      expect(chat.map((m) => m.queueState), [
        QueuedState.none,
        QueuedState.waiting,
      ]);

      await tester.pumpWidget(view(chat));
      await tester.pumpAndSettle();

      expect(find.text('Queued'), findsOneWidget);
      expect(find.byKey(const ValueKey('claude-queued-1')), findsOneWidget);
      expect(
        find.textContaining('And the docs', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Sent while working'), findsNothing);
    });

    for (final width in [360.0, 1440.0]) {
      testWidgets('fits a ${width.toInt()} px pane at text scale 1.6', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final chat = chatMessagesFromTranscript([
          TranscriptMessage(
            role: 'user',
            text: 'And the docs ${'and more words ' * 30}',
            queueState: QueuedState.waiting,
          ),
        ]);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: Scaffold(body: ChatTranscriptView(messages: chat)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Queued'), findsOneWidget);
      });
    }

    testWidgets('once taken, its words show once, as sent', (tester) async {
      final chat = chatMessagesFromTranscript(const [
        TranscriptMessage(
          role: 'user',
          text: 'And the docs',
          queueState: QueuedState.retired,
        ),
        TranscriptMessage(role: 'user', text: 'And the docs', queued: true),
      ]);
      expect(chat.map((m) => m.queueState), [QueuedState.sent]);

      await tester.pumpWidget(view(chat));
      await tester.pumpAndSettle();

      expect(find.text('Queued'), findsNothing);
      expect(find.text('Sent while working'), findsOneWidget);
      expect(
        find.textContaining('And the docs', findRichText: true),
        findsOneWidget,
      );
    });

    test('a retired row alone draws nothing', () {
      expect(
        chatMessagesFromTranscript(const [
          TranscriptMessage(
            role: 'user',
            text: 'And the docs',
            queueState: QueuedState.retired,
          ),
        ]),
        isEmpty,
      );
    });

    test('a waiting row opens no turn', () {
      final t0 = DateTime.utc(2026, 11, 13, 10);
      final footers = turnFooters([
        ChatMessage(role: 'user', text: 'Run the tests', at: t0),
        ChatMessage(
          role: 'agent',
          text: 'Running.',
          at: t0.add(const Duration(seconds: 5)),
        ),
        ChatMessage(
          role: 'user',
          text: 'And the docs',
          at: t0.add(const Duration(seconds: 6)),
          queueState: QueuedState.waiting,
        ),
        ChatMessage(
          role: 'agent',
          text: 'Done.',
          at: t0.add(const Duration(seconds: 9)),
        ),
      ], lastTurnOver: true);
      expect(footers.keys, [3]);
      expect(footers[3]!.elapsed, const Duration(seconds: 9));
    });
  });

  testWidgets('a pasted image is a thumbnail in the person\'s bubble', (
    tester,
  ) async {
    final chat = chatMessagesFromTranscript(const [
      TranscriptMessage(
        role: 'user',
        text: '[Image #1] why is this cut off?',
        images: ['/cache/tool-images/pasted.png'],
      ),
    ]);
    expect(chat.single.images, ['/cache/tool-images/pasted.png']);

    await tester.pumpWidget(view(chat));
    await tester.pump();
    final strip = tester.widget<TranscriptImageStrip>(
      find.byType(TranscriptImageStrip),
    );
    expect(strip.returned, ['/cache/tool-images/pasted.png']);
    expect(
      find.textContaining('why is this cut off?', findRichText: true),
      findsOneWidget,
    );
  });
}
