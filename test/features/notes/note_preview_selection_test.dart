import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/notes/presentation/note_tab_parts.dart';
import 'package:karmashala_ui/theme.dart';

/// A note's preview can be selected as a whole and copied.
///
/// The owner, 2026-09-17: *"note preview cannot copy or select all"*. The
/// preview drew each Markdown block as its own selectable text, so a drag
/// stopped at the end of a paragraph, select-all took one paragraph, and the
/// chord did nothing until a block had been clicked into.
void main() {
  const body = '# Plan\n\nFirst paragraph.\n\nSecond paragraph.\n';

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

  Future<void> pumpPreview(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: NotePreview(body: body)),
    ),
  );

  testWidgets('select-all then copy takes every block, with no click first', (
    tester,
  ) async {
    await pumpPreview(tester);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();

    expect(copied, isNotEmpty, reason: 'the chord reached nothing');
    expect(copied.last, contains('Plan'));
    expect(copied.last, contains('First paragraph.'));
    expect(copied.last, contains('Second paragraph.'));
  });

  testWidgets('one drag runs across two paragraphs', (tester) async {
    await pumpPreview(tester);
    await tester.pump();

    final first = tester.getRect(find.textContaining('First paragraph'));
    final second = tester.getRect(find.textContaining('Second paragraph'));
    final gesture = await tester.startGesture(
      first.centerLeft + const Offset(1, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(second.centerRight - const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();

    expect(copied, isNotEmpty);
    expect(copied.last, contains('First paragraph.'));
    expect(copied.last, contains('Second paragraph'));
  });
}
