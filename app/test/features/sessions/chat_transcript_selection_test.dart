import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_ui/theme.dart';

/// A conversation selects as one text, the way a note's preview does.
///
/// The owner, 2026-09-17: *"session chat messages can only be selected one
/// block at a time"*. Every Markdown block, tool row and error card was its own
/// selectable text, so a drag stopped at the end of a paragraph and nothing
/// reached from one message into the next.
void main() {
  final written = DateTime.now().subtract(const Duration(minutes: 5));

  List<ChatMessage> conversation() => [
    ChatMessage(role: 'user', text: 'Please fix the login flow.', at: written),
    ChatMessage(
      role: 'agent',
      text:
          'First paragraph.\n\nSecond paragraph.\n\n'
          '```dart\nfinal answer = 42;\n```',
      at: written,
    ),
    const ChatMessage(role: 'tool', text: 'Session ended.'),
    const ChatMessage(role: 'error', text: 'It broke.'),
    ChatMessage(
      role: 'agent',
      text: 'Closing words about lib/main.dart here.',
      at: written,
    ),
  ];

  late List<String> copied;
  late List<String> tapped;

  setUp(() {
    copied = [];
    tapped = [];
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

  late TextEditingController composer;
  late FocusNode composerFocus;

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    composer = TextEditingController(text: 'a half-typed reply');
    composerFocus = FocusNode(debugLabel: 'composer');
    addTearDown(composer.dispose);
    addTearDown(composerFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ChatTranscriptView(
            messages: conversation(),
            onPathTap: tapped.add,
            onSaveNote: (_, _) {},
            footer: TextField(controller: composer, focusNode: composerFocus),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A point just inside [needle], at its first glyph or its last.
  Offset pointIn(WidgetTester tester, String needle, {bool end = false}) {
    final rect = tester.getRect(
      find.textContaining(needle, findRichText: true).first,
    );
    return end
        ? rect.centerRight - const Offset(1, 0)
        : rect.centerLeft + const Offset(1, 0);
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.meta
        : LogicalKeyboardKey.control;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('one drag runs across paragraphs and into the next message', (
    tester,
  ) async {
    await pumpChat(tester);

    await drag(
      tester,
      pointIn(tester, 'First paragraph'),
      pointIn(tester, 'Session ended', end: true),
    );
    await chord(tester, LogicalKeyboardKey.keyC);

    expect(copied, isNotEmpty, reason: 'the chord reached nothing');
    expect(
      copied.last,
      'First paragraph.\n\nSecond paragraph.\n\nfinal answer = 42;\n\n'
      'Session ended.',
    );
  }, variant: TargetPlatformVariant.desktop());

  testWidgets(
    'select-all then copy takes every built message and none of the chrome',
    (tester) async {
      await pumpChat(tester);

      // A click on text is what hands the transcript the keyboard.
      await tester.tapAt(
        pointIn(tester, 'Closing words'),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyA);
      await chord(tester, LogicalKeyboardKey.keyC);

      expect(copied, isNotEmpty, reason: 'the chord reached nothing');
      expect(
        copied.last,
        'Please fix the login flow.\n\n'
        'First paragraph.\n\nSecond paragraph.\n\nfinal answer = 42;\n\n'
        'Session ended.\n\n'
        'It broke.\n\n'
        'Closing words about lib/main.dart here.',
      );
      expect(composer.selection.isCollapsed, isTrue);
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets('select-all in the composer takes the composer only', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await chord(tester, LogicalKeyboardKey.keyA);
    await chord(tester, LogicalKeyboardKey.keyC);

    expect(
      composer.selection,
      const TextSelection(baseOffset: 0, extentOffset: 18),
    );
    expect(copied, ['a half-typed reply']);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a click on empty space clears the selection', (tester) async {
    await pumpChat(tester);
    await drag(
      tester,
      pointIn(tester, 'First paragraph'),
      pointIn(tester, 'Second paragraph', end: true),
    );
    final list = tester.getRect(find.byType(ListView));
    await tester.tapAt(
      Offset(list.right - 4, pointIn(tester, 'Second paragraph').dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kDoubleTapTimeout);
    await chord(tester, LogicalKeyboardKey.keyC);

    expect(copied, isEmpty);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a right-click offers Copy and Select all', (tester) async {
    await pumpChat(tester);
    await drag(
      tester,
      pointIn(tester, 'First paragraph'),
      pointIn(tester, 'Second paragraph', end: true),
    );

    await tester.tapAt(
      pointIn(tester, 'Second paragraph') + const Offset(20, 0),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Select all'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, ['First paragraph.\n\nSecond paragraph.']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a path link still takes its click', (tester) async {
    await pumpChat(tester);

    final paragraph = tester
        .renderObjectList<RenderParagraph>(find.byType(RichText))
        .firstWhere((p) => p.text.toPlainText().contains('lib/main.dart'));
    final at = paragraph.text.toPlainText().indexOf('lib/main.dart');
    final box = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: at, extentOffset: at + 13),
        )
        .first;
    await tester.tapAt(
      paragraph.localToGlobal(box.toRect().center),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kDoubleTapTimeout);

    expect(tapped, ['lib/main.dart']);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets("a message's own Copy still copies the whole message", (
    tester,
  ) async {
    await pumpChat(tester);
    await drag(
      tester,
      pointIn(tester, 'First paragraph'),
      pointIn(tester, 'Second paragraph', end: true),
    );

    await tester.tap(find.byTooltip('Copy message').first);
    await tester.pump();
    expect(copied, ['Please fix the login flow.']);
    await tester.pump(const Duration(seconds: 2));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('selecting rebuilds no row', (tester) async {
    await pumpChat(tester);

    ChatTranscriptView.debugMessageBuildCount = 0;
    await drag(
      tester,
      pointIn(tester, 'First paragraph'),
      pointIn(tester, 'Closing words', end: true),
    );
    await chord(tester, LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();

    expect(ChatTranscriptView.debugMessageBuildCount, 0);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('opened reasoning is part of the selection', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: ChatTranscriptView(
            messages: [
              ChatMessage(
                role: 'agent',
                text: 'The answer.',
                thinking: 'weighing it up',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thought'));
    await tester.pumpAndSettle();

    await tester.tapAt(
      pointIn(tester, 'The answer'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kDoubleTapTimeout);
    await chord(tester, LogicalKeyboardKey.keyA);
    await chord(tester, LogicalKeyboardKey.keyC);

    expect(copied.last, 'weighing it up\n\nThe answer.');
  }, variant: TargetPlatformVariant.desktop());

  group(
    'a long conversation, where only the rows near the screen are built',
    () {
      Future<void> pumpLong(WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1200, 900);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              // Room above the list: a drag has to leave it to scroll it.
              body: Padding(
                padding: const EdgeInsets.only(top: 100),
                child: ChatTranscriptView(
                  messages: [
                    for (var i = 0; i < 40; i++)
                      ChatMessage(
                        role: i.isEven ? 'user' : 'agent',
                        text: 'turn $i first.\n\nturn $i second.',
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      ScrollPosition position(WidgetTester tester) =>
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;

      List<int> turnsIn(String text) => [
        for (final match in RegExp(r'turn (\d+) first').allMatches(text))
          int.parse(match[1]!),
      ];

      testWidgets('a selection scrolled out of sight still copies as it read', (
        tester,
      ) async {
        await pumpLong(tester);
        await drag(
          tester,
          pointIn(tester, 'turn 38 first'),
          pointIn(tester, 'turn 39 second', end: true),
        );

        // Far past the cache extent: the framework keeps a row alive while it
        // holds a selection, off-screen and with no place on it.
        position(tester).jumpTo(200);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('turn 30', findRichText: true),
          findsNothing,
        );
        await chord(tester, LogicalKeyboardKey.keyC);

        expect(
          copied.last,
          'turn 38 first.\n\nturn 38 second.\n\n'
          'turn 39 first.\n\nturn 39 second.',
        );
      }, variant: TargetPlatformVariant.desktop());

      testWidgets(
        'a drag past the top edge scrolls, and keeps what it crossed',
        (tester) async {
          await pumpLong(tester);
          final list = tester.getRect(find.byType(ListView));
          final from = pointIn(tester, 'turn 39 second', end: true);
          final gesture = await tester.startGesture(
            from,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await gesture.moveTo(Offset(from.dx, list.top - 30));
          for (var frame = 0; frame < 120; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          await gesture.up();
          await tester.pump();
          await chord(tester, LogicalKeyboardKey.keyC);

          final turns = turnsIn(copied.last);
          expect(turns.last, 39);
          expect(turns.first, lessThan(25), reason: 'the drag never scrolled');
          expect(turns, [for (var i = turns.first; i <= 39; i++) i]);
        },
        variant: TargetPlatformVariant.desktop(),
      );

      testWidgets(
        'select-all takes the built rows, and says nothing of the rest',
        (tester) async {
          await pumpLong(tester);
          await tester.tapAt(
            pointIn(tester, 'turn 39 first'),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await chord(tester, LogicalKeyboardKey.keyA);
          await chord(tester, LogicalKeyboardKey.keyC);

          final turns = turnsIn(copied.last);
          expect(turns.last, 39);
          expect(
            turns.first,
            greaterThan(0),
            reason: 'a lazy list built it all',
          );
        },
        variant: TargetPlatformVariant.desktop(),
      );

      testWidgets(
        'select-all with the selection scrolled away does not throw',
        (tester) async {
          // Flutter 3.47's own area reads an edge point an off-screen row does
          // not have: select, scroll it away, select all.
          await pumpLong(tester);
          await drag(
            tester,
            pointIn(tester, 'turn 38 first'),
            pointIn(tester, 'turn 39 second', end: true),
          );
          position(tester).jumpTo(200);
          await tester.pumpAndSettle();

          await chord(tester, LogicalKeyboardKey.keyA);
          expect(tester.takeException(), isNull);
          await chord(tester, LogicalKeyboardKey.keyC);
          expect(turnsIn(copied.last), containsAll([3, 38, 39]));
        },
        variant: TargetPlatformVariant.desktop(),
      );
    },
  );
}
