import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

/// **A run of tool calls reads as one line.**
///
/// Between two of the model's sentences, twenty file reads are one step; drawn
/// one per row they are a wall the reader scrolls past to find what was said.
/// Orca (*"read a tool batch as a group"*, v1.4.199) and Wake (*"collapsible
/// tool-call clusters"*) reached the same answer independently.
///
/// What must never collapse is the row somebody is looking for: a call that
/// failed, a call with no result yet, and a call the model reasoned its way to.
void main() {
  ChatMessage tool(
    String name, {
    String? output = 'done',
    bool isError = false,
    String? thinking,
  }) => ChatMessage(
    role: 'tool',
    text: name,
    thinking: thinking,
    tool: ToolActivity(
      name: name,
      output: output,
      isError: isError,
    ),
  );

  ChatMessage said(String text) => ChatMessage(role: 'agent', text: text);

  group('grouping', () {
    test('a run of three or more finished calls is one row', () {
      final rows = transcriptRows([
        said('working'),
        tool('Read'),
        tool('Read'),
        tool('Bash'),
        said('done'),
      ]);

      expect(rows, hasLength(3));
      expect(rows[1].isBatch, isTrue);
      expect(rows[1].from, 1);
      expect(rows[1].to, 4);
      expect(rows[1].length, 3);
    });

    test('two in a row are left as themselves', () {
      final rows = transcriptRows([tool('Read'), tool('Read'), said('done')]);

      expect(rows, hasLength(3));
      expect(rows.every((r) => !r.isBatch), isTrue);
    });

    test('a failure is never inside a batch', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Bash', isError: true),
        tool('Read'),
        tool('Read'),
      ]);

      // Two runs of two around it: neither reaches the minimum, so all five
      // stand alone and the failure is exactly where the eye lands.
      expect(rows, hasLength(5));
      expect(rows.every((r) => !r.isBatch), isTrue);
    });

    test('a call still running is never inside a batch', () {
      final messages = [
        tool('Read'),
        tool('Read'),
        tool('Read'),
        tool('Bash', output: null),
      ];
      final rows = transcriptRows(messages);

      expect(rows, hasLength(2));
      expect(rows.first.isBatch, isTrue);
      expect(rows.first.to, 3);
      expect(rows.last.isBatch, isFalse);
      expect(messages[rows.last.from].tool!.name, 'Bash');
    });

    test('a call the model reasoned its way to keeps its own row', () {
      final rows = transcriptRows([
        tool('Read'),
        tool('Read'),
        tool('Grep', thinking: 'where does this get called'),
        tool('Read'),
      ]);

      expect(rows.every((r) => !r.isBatch), isTrue);
    });

    test('an empty transcript has no rows', () {
      expect(transcriptRows(const []), isEmpty);
    });
  });

  group('what the line says', () {
    test('names the calls and how many of each, in first-seen order', () {
      expect(
        describeToolBatch([tool('Read'), tool('Bash'), tool('Read')]),
        'Read ×2 · Bash',
      );
    });
  });

  group('on screen', () {
    Future<void> pump(WidgetTester tester, List<ChatMessage> messages) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ChatTranscriptView(messages: messages)),
          ),
        );

    testWidgets('a batch is one line until it is opened', (tester) async {
      await pump(tester, [
        said('working'),
        tool('Read'),
        tool('Read'),
        tool('Bash'),
      ]);

      expect(find.text('3 tool calls'), findsOneWidget);
      expect(find.text('Read ×2 · Bash'), findsOneWidget);
      // The calls themselves are not drawn yet.
      expect(find.text('Bash', findRichText: true), findsNothing);

      await tester.tap(find.text('3 tool calls'));
      await tester.pumpAndSettle();

      expect(find.text('3 tool calls'), findsOneWidget);
      expect(find.textContaining('Bash', findRichText: true), findsWidgets);
    });

    testWidgets('what the agent said is never collapsed', (tester) async {
      await pump(tester, [
        said('here is the plan'),
        tool('Read'),
        tool('Read'),
        tool('Read'),
        said('and here is what I found'),
      ]);

      expect(find.textContaining('here is the plan'), findsOneWidget);
      expect(find.textContaining('and here is what I found'), findsOneWidget);
    });
  });
}
