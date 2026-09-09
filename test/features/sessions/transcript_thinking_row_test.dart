import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

/// **Where a thinking block is drawn, and why a tool row can carry one.**
///
/// The accordion was an agent-row affair, which is all Claude Code needs: its
/// reasoning arrives as part of the turn's own text. Antigravity writes it as a
/// field on the record, and **425 of the 435 blocks on this machine sit on a
/// record whose only other payload is a tool call** — so an accordion the agent
/// row alone could show would show 9 of 435. The row is the same widget in the
/// same place; only the role that may carry it is new.
void main() {
  Widget wrap(List<ChatMessage> messages) => MaterialApp(
    home: Scaffold(body: ChatTranscriptView(messages: messages)),
  );

  testWidgets('an agent row still shows its reasoning', (tester) async {
    await tester.pumpWidget(
      wrap(const [
        ChatMessage(
          role: 'agent',
          text: 'Rendered the chart.',
          thinking: 'first the axes\nthen the series',
        ),
      ]),
    );

    expect(find.text('Thought for 2 lines'), findsOneWidget);
  });

  testWidgets('a tool row carrying reasoning shows it too', (tester) async {
    await tester.pumpWidget(
      wrap(const [
        ChatMessage(
          role: 'tool',
          text: 'run_command(ls -1)',
          tool: ToolActivity(name: 'run_command', subject: 'ls -1'),
          thinking: 'the folder first, then the diff',
        ),
      ]),
    );

    expect(find.text('Thought'), findsOneWidget);
    await tester.tap(find.text('Thought'));
    await tester.pump();
    expect(find.text('the folder first, then the diff'), findsOneWidget);
  });

  testWidgets('a tool row with no reasoning shows none', (tester) async {
    await tester.pumpWidget(
      wrap(const [
        ChatMessage(
          role: 'tool',
          text: 'run_command(ls -1)',
          tool: ToolActivity(name: 'run_command', subject: 'ls -1'),
        ),
      ]),
    );

    expect(find.textContaining('Thought'), findsNothing);
  });

  testWidgets('a tool row is never scanned for thinking tags', (tester) async {
    // The agent row's fallback reads `<thinking>` out of the text, which is
    // right for a turn somebody wrote and wrong for a tool row: its text is a
    // command, and a command that mentions the tag means it literally.
    await tester.pumpWidget(
      wrap(const [
        ChatMessage(
          role: 'tool',
          text: 'Bash(grep -n "<thinking>helical</thinking>" lib/)',
          tool: ToolActivity(
            name: 'Bash',
            subject: 'grep -n "<thinking>helical</thinking>" lib/',
          ),
        ),
      ]),
    );

    expect(find.textContaining('Thought'), findsNothing);
  });
}
