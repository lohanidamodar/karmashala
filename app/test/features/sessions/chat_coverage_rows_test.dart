import 'package:agent_cli/read.dart'
    show TranscriptMessage, kTranscriptCommandRole, kTranscriptNoticeRole;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
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
}
