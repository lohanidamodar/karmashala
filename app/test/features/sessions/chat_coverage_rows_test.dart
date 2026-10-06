import 'package:agent_cli/read.dart'
    show TranscriptMessage, kTranscriptCommandRole, kTranscriptNoticeRole;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_image_preview.dart';
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
    final preview = tester.widget<TranscriptImagePreview>(
      find.byType(TranscriptImagePreview),
    );
    expect(preview.path, '/cache/tool-images/pasted.png');
    expect(
      find.textContaining('why is this cut off?', findRichText: true),
      findsOneWidget,
    );
  });
}
