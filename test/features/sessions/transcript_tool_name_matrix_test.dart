import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../../support/window_matrix.dart';

/// An MCP tool's raw name is longer than a narrow pane; it must give way
/// before the row's Save-note and Copy actions do.
void main() {
  const cells = [
    ...windowMatrix,
    WindowCell('480x560 pane', Size(480, 560)),
    WindowCell('360x560 pane', Size(360, 560)),
    WindowCell('360x560 pane @1.3x', Size(360, 560), textScale: 1.3),
  ];
  const mcpName = 'mcp__claude-in-chrome__read_console_messages';

  Widget build() => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(
        onSaveNote: (_, _) {},
        messages: const [
          ChatMessage(
            role: 'tool',
            text: 'x',
            tool: ToolActivity(
              name: mcpName,
              subject: 'tab 3',
              output: 'boom',
              isError: true,
            ),
          ),
        ],
      ),
    ),
  );

  testWidgets('a long MCP tool name does not push the row actions out', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      matrix: cells,
      checkFocus: false,
      build: build,
    );
  });

  testWidgets('the full tool name stays reachable in a tooltip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == mcpName,
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Copy message'), findsOneWidget);
    final copy = tester.getRect(find.byTooltip('Copy message'));
    expect(copy.right, lessThanOrEqualTo(360));
  });

  test('an MCP name reads as its server and tool', () {
    expect(
      toolDisplayName(mcpName),
      'claude-in-chrome · read_console_messages',
    );
    expect(toolDisplayName('Bash'), 'Bash');
    expect(toolDisplayName('mcp__solo'), 'mcp__solo');
  });
}
