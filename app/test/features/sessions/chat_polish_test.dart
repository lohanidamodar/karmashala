import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:karmashala_ui/theme.dart';

/// The small things the best chat views do: a failure shows its end, says its
/// exit code and keeps its colours; a long prompt folds; a time names itself.
void main() {
  Future<void> show(WidgetTester tester, List<ChatMessage> messages) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: ChatTranscriptView(messages: messages)),
      ),
    );
    await tester.pump();
  }

  Future<void> body(WidgetTester tester, ChatMessage message) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: ToolActivityBody(activity: message.tool!)),
      ),
    );
    await tester.pump();
  }

  Finder text(String value) => find.textContaining(value, findRichText: true);

  ChatMessage call(String output, {bool error = false}) => ChatMessage(
    role: 'tool',
    text: '',
    tool: ToolActivity(
      name: 'Bash',
      subject: 'flutter test',
      output: output,
      isError: error,
    ),
  );

  final long = [
    'Exit code 1',
    for (var i = 0; i < 20; i++) 'line $i',
    'FAILED: 2 tests',
  ].join('\n');

  testWidgets('a failed command shows how it ended, and its exit code', (
    tester,
  ) async {
    await body(tester, call(long, error: true));
    expect(find.byKey(const ValueKey('tool-output-tail')), findsOneWidget);
    expect(text('FAILED: 2 tests'), findsWidgets);
    expect(find.text('Failed · exit 1'), findsOneWidget);
  });

  testWidgets('a failure shorter than the fold shows whole', (tester) async {
    await body(tester, call('permission denied', error: true));
    expect(tester.takeException(), isNull);
    expect(text('permission denied'), findsWidgets);
    expect(find.text('Failed'), findsOneWidget);
  });

  testWidgets('a command that passed shows how it began', (tester) async {
    await body(tester, call(long.replaceFirst('Exit code 1\n', '')));
    expect(find.byKey(const ValueKey('tool-output-head')), findsOneWidget);
    expect(text('line 0'), findsWidgets);
  });

  test('the exit code is read only where the output names one', () {
    expect(commandExitCode('Exit code 127\nnot found'), 127);
    expect(commandExitCode('exit code: 2'), 2);
    expect(commandExitCode('all good'), isNull);
  });

  testWidgets('output in colour is drawn in colour, never as escapes', (
    tester,
  ) async {
    await body(tester, call('\x1B[32m✓ passed\x1B[0m'));
    expect(text('[32m'), findsNothing);
    expect(text('✓ passed'), findsWidgets);
  });

  testWidgets('a long prompt folds to eight lines', (tester) async {
    final prompt = List.generate(30, (i) => 'prompt line $i').join('\n\n');
    await show(tester, [ChatMessage(role: 'user', text: prompt)]);
    expect(text('prompt line 3'), findsOneWidget);
    expect(text('prompt line 29'), findsNothing);
    expect(find.text('Show all (59 lines)'), findsOneWidget);
  });

  test('a moment reads as a person writes it', () {
    expect(
      messageMoment(DateTime(2026, 10, 7, 18, 7)),
      'Wed 7 Oct 2026, 18:07',
    );
  });
}
