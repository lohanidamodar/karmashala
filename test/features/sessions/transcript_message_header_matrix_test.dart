import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../../support/window_matrix.dart';

/// Every role's header — glyph, name, age, actions — shares one row shape, and
/// that row has to hold in the narrowest pane the side panel allows.
void main() {
  const cells = [
    ...windowMatrix,
    WindowCell('240x560 pane', Size(240, 560)),
    WindowCell('240x560 pane @2x', Size(240, 560), textScale: 2),
  ];

  final at = DateTime.now().subtract(const Duration(minutes: 42));
  Widget build() => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(
        onSaveNote: (_, _) {},
        messages: [
          ChatMessage(role: 'user', text: 'Fix the login', at: at),
          ChatMessage(
            role: 'agent',
            text: '<thought>Look at auth first.</thought>Done.',
            at: at,
          ),
          ChatMessage(role: 'error', text: 'Session failed.', at: at),
          ChatMessage(
            role: 'tool',
            text: 'Read(lib/auth.dart)',
            at: at,
            tool: const ToolActivity(
              name: 'Read',
              subject: 'lib/auth.dart',
              output: 'ok',
            ),
          ),
          ChatMessage(role: kCompactionNoticeRole, text: 'Compacted.', at: at),
        ],
      ),
    ),
  );

  testWidgets('every role header holds in a narrow pane at large text', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      matrix: cells,
      checkFocus: false,
      build: build,
    );
  });

  testWidgets('each header keeps its age and actions', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // Only the conversation's own turns are dated; tool rows repeat too often.
    expect(find.text('42m'), findsNWidgets(2));
    expect(find.byTooltip('Copy message'), findsNWidgets(5));
    expect(find.byTooltip('Save as note'), findsNWidgets(4));
    // The reasoning is lifted out of the agent's words, `<thought>` included.
    expect(find.textContaining('<thought>'), findsNothing);
  });
}
