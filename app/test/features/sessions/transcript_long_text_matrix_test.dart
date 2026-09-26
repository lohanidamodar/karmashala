import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

import '../../support/window_matrix.dart';

/// Text an agent really writes and no layout plans for: a hash with no break
/// in it, a code line wider than any pane, a path twelve directories deep. The
/// conversation is read in a 240px side panel as often as in the editor area.
void main() {
  final unbroken = 'a1b2c3d4' * 40;
  final deepPath =
      '/Users/someone/Documents/projects/${'nested-directory/' * 12}'
      'a_file_with_a_rather_long_name_indeed.dart';
  final wideCode = 'final value = ${'someFunction(argument) + ' * 12}0;';

  List<ChatMessage> conversation() => [
    ChatMessage(role: 'user', text: 'Look at $deepPath and $unbroken'),
    ChatMessage(
      role: 'agent',
      text:
          '<thinking>$unbroken</thinking>'
          'Here it is:\n\n```dart\n$wideCode\n```\n\nSee `$deepPath`.',
      at: DateTime.now().subtract(const Duration(minutes: 3)),
    ),
    ChatMessage(role: 'error', text: unbroken),
    ChatMessage(
      role: 'tool',
      text: 'mcp__a_server_with_a_long_name__and_a_tool_with_one_too',
      tool: ToolActivity(
        name: 'mcp__a_server_with_a_long_name__and_a_tool_with_one_too',
        subject: '$deepPath\n$unbroken',
        output: '$wideCode\n$unbroken\nthree\nfour\nfive',
        isError: true,
      ),
    ),
  ];

  // One message per pump: a lazy list lays out only what is near the fold, so
  // a whole conversation at 240px would leave most rows unmeasured.
  Widget build(ChatMessage message) => MaterialApp(
    home: Scaffold(body: ChatTranscriptView(messages: [message])),
  );

  const sidePanel = WindowCell('240x560 (side panel)', Size(240, 560));
  const sidePanelLargeText = WindowCell(
    '240x560 @ 1.3x text',
    Size(240, 560),
    textScale: 1.3,
  );
  const cells = [sidePanel, sidePanelLargeText, minimumWindowLargeText];

  /// Opens every toggle a row has. Pressed through the widgets rather than
  /// tapped: at 240px a row taller than the pane may have its toggle's centre
  /// off screen.
  Future<void> unfold(WidgetTester tester) async {
    final toggles = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith('Show the whole') ?? false),
        skipOffstage: false,
      ),
      matching: find.byType(TextButton, skipOffstage: false),
    );
    final pressed = toggles.evaluate().toList();
    for (final element in pressed) {
      (element.widget as TextButton).onPressed!();
    }
    final thought = find.ancestor(
      of: find.textContaining('Thought', skipOffstage: false),
      matching: find.byType(InkWell, skipOffstage: false),
    );
    final opened = thought.evaluate().toList();
    for (final element in opened) {
      (element.widget as InkWell).onTap!();
    }
    await tester.pump();
    // Proof the unfolded state is what gets measured.
    if (pressed.isNotEmpty) {
      expect(find.text('Less', skipOffstage: false), findsNWidgets(2));
    }
    if (opened.isNotEmpty) {
      expect(
        find.textContaining('a1b2c3d4', skipOffstage: false),
        findsWidgets,
      );
    }
  }

  final roles = conversation();
  for (var i = 0; i < roles.length; i++) {
    testWidgets('a long ${roles[i].role} row fits every pane, folded and not', (
      tester,
    ) async {
      final message = conversation()[i];
      // A scrolling row taller than the pane has stops below the fold by
      // design; the list scrolls to them.
      await expectSurvivesWindowMatrix(
        tester,
        build: () => build(message),
        matrix: cells,
        checkFocus: false,
      );
      await expectSurvivesWindowMatrix(
        tester,
        build: () => build(message),
        matrix: cells,
        checkFocus: false,
        warmUp: unfold,
      );
    });
  }
}
