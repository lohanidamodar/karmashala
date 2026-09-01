import 'package:chitragupta/src/features/sessions/domain/tool_activity.dart';
import 'package:chitragupta/src/features/sessions/presentation/chat_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_matrix.dart';

/// The tool row is the densest thing in the conversation — an eyebrow, a
/// monospace command, an expander, and a panel of output — and it is drawn in a
/// pane that is routinely the narrowest column on screen. A command that
/// overflows at 720x560, or an expander pushed off the edge at 1.3x text, is
/// the row failing exactly where the owner reads it.
void main() {
  const long =
      'git log --oneline -20 \\\n'
      '  --author=someone-with-a-long-name \\\n'
      '  --since=yesterday';

  Widget build() => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(
        messages: const [
          ChatMessage(
            role: 'tool',
            text: 'Bash(git status --short)',
            tool: ToolActivity(
              name: 'Bash',
              subject: 'git status --short',
              output: 'nothing to commit, working tree clean',
            ),
          ),
          ChatMessage(
            role: 'tool',
            text: 'Bash(git log)',
            tool: ToolActivity(
              name: 'Bash',
              subject: long,
              output: 'one\ntwo\nthree\nfour\nfive\nsix',
              outputTruncated: true,
              isError: true,
            ),
          ),
        ],
      ),
    ),
  );

  testWidgets('a tool row survives the window matrix', (tester) async {
    await expectSurvivesWindowMatrix(tester, build: build);
  });

  testWidgets('...and so does everything it can unfold', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: build,
      warmUp: (tester) async {
        await tester.tap(find.byTooltip('Show the whole command'));
        await tester.pump();
        await tester.tap(find.byTooltip('Show the whole output'));
        await tester.pump();
      },
    );
  });
}
