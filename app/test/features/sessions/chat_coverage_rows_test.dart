import 'package:agent_cli/read.dart' show kTranscriptNoticeRole;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

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
}
