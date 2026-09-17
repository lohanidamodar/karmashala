import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/transcript.dart';

/// What a selection copies. Flutter joins selected texts with nothing between
/// them, so two paragraphs came out as one run-on line and a list as one word.
void main() {
  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<String> copyAll(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptSelectionArea(
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.byType(RichText).first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    return copied.last;
  }

  testWidgets('blocks copy a blank line apart, code as it was written', (
    tester,
  ) async {
    final text = await copyAll(
      tester,
      const MarkdownMessage(
        '# Plan\n\nFirst paragraph.\n\n```\none\n  two\n```\n\nLast words.',
        selectable: false,
      ),
    );
    expect(text, 'Plan\n\nFirst paragraph.\n\none\n  two\n\nLast words.');
  });

  testWidgets('a list copies one item to a line, each behind its bullet', (
    tester,
  ) async {
    final text = await copyAll(
      tester,
      const MarkdownMessage(
        'Steps:\n\n- first\n- second\n- third',
        selectable: false,
      ),
    );
    expect(text, 'Steps:\n\n• first\n• second\n• third');
  });

  testWidgets('a table copies one row to a line', (tester) async {
    final text = await copyAll(
      tester,
      const MarkdownMessage(
        '| File | Lines |\n| --- | --- |\n| a.dart | 10 |\n| b.dart | 20 |',
        selectable: false,
      ),
    );
    expect(text, 'File Lines\na.dart 10\nb.dart 20');
  });

  testWidgets('two turns copy a blank line apart, without their chrome', (
    tester,
  ) async {
    final text = await copyAll(
      tester,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final words in ['Asked.', 'Answered.'])
            TranscriptSelectionGroup(
              endsTurn: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TranscriptRoleHeader(
                    icon: Icons.person,
                    label: 'You',
                    color: Colors.blue,
                    meta: const Text('5m'),
                  ),
                  MarkdownMessage(words, selectable: false),
                ],
              ),
            ),
        ],
      ),
    );
    expect(text, 'Asked.\n\nAnswered.');
  });
}
