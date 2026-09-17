import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// The phone's conversation selects as one text: a long press picks a word,
/// and its handles drag across blocks and into the next turn. Each block used
/// to be its own selectable text, so a handle stopped at the end of a paragraph.
void main() {
  const turns = [
    CompanionChatMessage(role: 'user', text: 'Please fix the login flow.'),
    CompanionChatMessage(
      role: 'agent',
      text: 'First paragraph.\n\nSecond paragraph.',
    ),
    CompanionChatMessage(role: 'tool', text: 'Ran the tests.'),
    CompanionChatMessage(role: 'error', text: 'It broke.'),
  ];

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

  Future<void> openSession(
    WidgetTester tester,
    List<CompanionChatMessage> messages,
  ) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(
        sessions: [summary('s1', title: 'Fix the login flow')],
        transcripts: {'s1': messages},
      ),
      home: const SessionViewScreen(sessionId: 's1'),
    );
    await tester.pumpAndSettle();
  }

  RenderParagraph paragraphOf(WidgetTester tester, String needle) => tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .firstWhere((p) => p.text.toPlainText().contains(needle));

  /// The middle of [word], wherever it was drawn.
  Offset wordIn(WidgetTester tester, String needle, String word) {
    final paragraph = paragraphOf(tester, needle);
    final at = paragraph.text.toPlainText().indexOf(word);
    final box = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: at, extentOffset: at + word.length),
        )
        .first;
    return paragraph.localToGlobal(box.toRect().center);
  }

  testWidgets('a long press selects a word, and its handle drags on into the '
      'next turn', (tester) async {
    await openSession(tester, turns);

    await tester.longPressAt(wordIn(tester, 'First paragraph', 'First'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);

    // The end handle hangs under the last selected glyph.
    final first = paragraphOf(tester, 'First paragraph');
    final selected = first.getBoxesForSelection(first.selections.single).last;
    final handle =
        first.localToGlobal(selected.toRect().bottomRight) + const Offset(2, 8);
    final gesture = await tester.startGesture(handle);
    await tester.pump();
    final target = wordIn(tester, 'Ran the tests', 'tests');
    await gesture.moveTo(target - const Offset(0, 40));
    await tester.pump();
    // A handle moves the edge by how far it was dragged, from the text it hung
    // under — so the thumb ends up below the line it is selecting.
    await gesture.moveTo(target + const Offset(120, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, ['First paragraph.\n\nSecond paragraph.\n\nRan the tests.']);
  });

  testWidgets('Select all takes every turn and none of the chrome', (
    tester,
  ) async {
    await openSession(tester, turns);

    await tester.longPressAt(wordIn(tester, 'It broke', 'broke'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copied, [
      'Please fix the login flow.\n\n'
          'First paragraph.\n\nSecond paragraph.\n\n'
          'Ran the tests.\n\n'
          'It broke.',
    ]);
  });

  testWidgets('a thumb still scrolls the conversation, selection or not', (
    tester,
  ) async {
    await openSession(tester, [
      for (var i = 0; i < 60; i++)
        CompanionChatMessage(
          role: i.isEven ? 'user' : 'agent',
          text: 'turn $i, long enough to be a line of its own.',
        ),
    ]);
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position().pixels, 0);

    // Straight down over message text: the list's drag, not the selection's.
    await tester.dragFrom(
      wordIn(tester, 'turn 57,', 'long'),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    final scrolled = position().pixels;
    expect(scrolled, greaterThan(200));
    expect(find.text('Jump to latest'), findsOneWidget);

    await tester.longPressAt(wordIn(tester, 'turn 50,', 'long'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);

    await tester.dragFrom(
      wordIn(tester, 'turn 50,', 'enough'),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    expect(position().pixels, greaterThan(scrolled));
  });
}
