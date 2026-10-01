import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tool_runs.dart';

/// The owner's third ask: command results were not visible in the conversation
/// at all. Claude Code answers every `tool_use` with a `tool_result` in the
/// next `user` entry, so the output was always there and was simply dropped.
///
/// A result is unbounded — a `Read` of a large file is megabytes — so it is
/// collapsed when it is long, and never allowed to push the conversation off
/// the screen.
void main() {
  final long = [
    'first-line',
    for (var i = 0; i < 30; i++) 'filler $i',
    'last-line',
  ].join('\n');

  Future<void> pumpTool(WidgetTester tester, ToolActivity activity) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: [
              ChatMessage(role: 'tool', text: activity.summary, tool: activity),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // A finished call is folded under its turn's line: open it to its card.
    await openToolRuns(tester);
  }

  testWidgets('a short result is simply shown', (tester) async {
    await pumpTool(
      tester,
      const ToolActivity(
        name: 'Bash',
        subject: 'git status --short',
        output: 'nothing to commit, working tree clean',
      ),
    );

    expect(find.textContaining('working tree clean'), findsOneWidget);
    // Nothing to expand: the whole result already fits.
    expect(find.byTooltip('Show the whole output'), findsNothing);
  });

  testWidgets('a long result is collapsed, not dumped into the view', (
    tester,
  ) async {
    await pumpTool(
      tester,
      ToolActivity(name: 'Bash', subject: 'git log', output: long),
    );

    expect(find.textContaining('first-line'), findsOneWidget);
    expect(find.textContaining('last-line'), findsNothing);
    expect(find.byTooltip('Show the whole output'), findsOneWidget);
  });

  testWidgets('...and the whole of it is one click away', (tester) async {
    await pumpTool(
      tester,
      ToolActivity(name: 'Bash', subject: 'git log', output: long),
    );

    await tester.tap(find.byTooltip('Show the whole output'));
    await tester.pumpAndSettle();

    expect(find.textContaining('last-line'), findsOneWidget);
    expect(find.byTooltip('Collapse the output'), findsOneWidget);
  });

  testWidgets('a call the agent was told had failed says so', (tester) async {
    await pumpTool(
      tester,
      const ToolActivity(
        name: 'Bash',
        subject: 'exit 1',
        output: 'command not found',
        isError: true,
      ),
    );

    expect(find.text('Failed'), findsOneWidget);
  });

  testWidgets('a result cut short on the way in admits it', (tester) async {
    await pumpTool(
      tester,
      ToolActivity(
        name: 'Read',
        subject: '/repo/huge.log',
        output: long,
        outputTruncated: true,
      ),
    );

    expect(find.textContaining('truncated'), findsOneWidget);
  });

  testWidgets('a call still running shows no output panel', (tester) async {
    await pumpTool(
      tester,
      const ToolActivity(name: 'Bash', subject: 'sleep 30'),
    );

    expect(find.byTooltip('Show the whole output'), findsNothing);
    expect(find.text('Failed'), findsNothing);
  });
}
