import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The owner's second report: "when commands are run, and when expanded, it
/// feels like the command is printed twice."
///
/// Two things were true. Every `Bash` row rendered the identical string
/// `tool: Bash` under a `TOOL` eyebrow, because the command itself was thrown
/// away by the reader — one real 265-message transcript held 23 pairs of
/// adjacent, byte-identical tool rows standing for different commands. And a
/// command too long for one line had nowhere to go, so the obvious way to give
/// it one is to print the head and then the whole thing underneath — which is
/// literally printing it twice. Neither is allowed to come back.
void main() {
  Future<void> pumpTools(
    WidgetTester tester,
    List<ToolActivity> activities,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: [
              for (final activity in activities)
                ChatMessage(role: 'tool', text: activity.summary, tool: activity),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  const multiline =
      'git log --oneline -20 \\\n'
      '  --author=me \\\n'
      '  --since=yesterday';
  const firstLine = 'git log --oneline -20 \\';

  testWidgets('two different commands are not the same row twice', (
    tester,
  ) async {
    await pumpTools(tester, const [
      ToolActivity(name: 'Bash', subject: 'git status --short'),
      ToolActivity(name: 'Bash', subject: 'git log -1'),
    ]);

    expect(find.text('git status --short'), findsOneWidget);
    expect(find.text('git log -1'), findsOneWidget);
    // The words that used to be the whole row, twice over.
    expect(find.textContaining('tool: Bash'), findsNothing);
  });

  testWidgets('a long command reads once collapsed', (tester) async {
    await pumpTools(tester, const [
      ToolActivity(name: 'Bash', subject: multiline),
    ]);

    expect(find.text(firstLine), findsOneWidget);
    expect(find.text(multiline), findsNothing);
  });

  testWidgets('...and once — not twice — when it is expanded', (tester) async {
    await pumpTools(tester, const [
      ToolActivity(name: 'Bash', subject: multiline),
    ]);

    await tester.tap(find.byTooltip('Show the whole command'));
    await tester.pumpAndSettle();

    // The whole point: expanding replaces the head, it does not repeat it.
    expect(find.text(multiline), findsOneWidget);
    expect(find.text(firstLine), findsNothing);
  });

  testWidgets('a one-line command has nothing to expand', (tester) async {
    await pumpTools(tester, const [
      ToolActivity(name: 'Bash', subject: 'git status --short'),
    ]);

    expect(find.byTooltip('Show the whole command'), findsNothing);
  });

  testWidgets('the expander says what it will do, both ways round', (
    tester,
  ) async {
    await pumpTools(tester, const [
      ToolActivity(name: 'Bash', subject: multiline),
    ]);

    expect(find.byTooltip('Show the whole command'), findsOneWidget);

    await tester.tap(find.byTooltip('Show the whole command'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Collapse the command'), findsOneWidget);
  });

  testWidgets('the expander carries its name into the semantics tree', (
    tester,
  ) async {
    // A tooltip is a mouse's affordance; Narrator reads the semantics tree,
    // which is what `test/support/window_matrix.dart` checks app-wide.
    final semantics = tester.ensureSemantics();

    await pumpTools(tester, const [
      ToolActivity(name: 'Bash', subject: multiline),
    ]);

    // `test/support/window_matrix.dart` counts a tooltip as a control's name
    // (`data.label … || data.tooltip …`), and that is where Flutter puts a
    // `Tooltip`'s message — so this asserts the same thing the app-wide
    // accessibility guard does, at the one control this row adds.
    final node = tester.getSemantics(
      find.byTooltip('Show the whole command'),
    );
    expect(node.tooltip, contains('Show the whole command'));
    semantics.dispose();
  });
}
