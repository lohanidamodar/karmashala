import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_edit_diff_card.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';

/// One bad message never blanks the chat; loading and streaming never move
/// the reader; long things fold; code and turns copy.
void main() {
  void size(WidgetTester tester, Size logical) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = logical;
    addTearDown(tester.view.reset);
  }

  Widget view(
    List<ChatMessage> messages, {
    MessageDetailBuilder? detail,
    Brightness brightness = Brightness.dark,
    double textScale = 1,
  }) => MaterialApp(
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: ChatTranscriptView(messages: messages, detailBuilder: detail),
      ),
    ),
  );

  List<ChatMessage> conversation(int n, {String last = 'turn'}) => [
    for (var i = 0; i < n; i++)
      ChatMessage(
        role: i.isEven ? 'user' : 'agent',
        text: i == n - 1 ? '$last $i' : 'turn $i',
      ),
  ];

  Finder text(String value) => find.textContaining(value, findRichText: true);

  group('a message that cannot be drawn', () {
    testWidgets('becomes one line, and the rest stay', (tester) async {
      // Restored inside the body: the binding checks before tear-downs run.
      final restore = installMessageBoundaries();
      size(tester, const Size(1200, 900));
      await tester.pumpWidget(
        view(
          conversation(6),
          detail: (m, ordinal) => ordinal == 3
              ? Builder(builder: (_) => throw StateError('bad row'))
              : null,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isStateError);
      await tester.pump();

      expect(find.text("This message couldn't be shown"), findsOneWidget);
      expect(text('turn 5'), findsWidgets);
      expect(text('turn 2'), findsWidgets);

      await tester.tap(find.text('Show raw'));
      await tester.pump();
      expect(find.text('turn 3'), findsOneWidget);
      restore();
    });

    testWidgets('outside a boundary the usual error widget still shows', (
      tester,
    ) async {
      final restore = installMessageBoundaries();
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: (_) => throw StateError('x'))),
      );
      expect(tester.takeException(), isStateError);
      expect(find.byType(ErrorWidget), findsOneWidget);
      restore();
    });
  });

  group('the reader stays where they are', () {
    testWidgets('while earlier messages load above', (tester) async {
      size(tester, const Size(1200, 900));
      await tester.pumpWidget(view(conversation(200)));
      await tester.pump();
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(200);
      await tester.pump();
      final anchor = text('turn 165').first;
      final before = tester.getTopLeft(anchor);
      scroll.position.jumpTo(60);
      await tester.pump();
      await tester.pump();
      expect(text('turn 120'), findsNothing, reason: 'not yet scrolled to');
      final after = tester.getTopLeft(anchor);
      // Only the 140 px the reader scrolled, not the page that loaded.
      expect(after.dy - before.dy, closeTo(140, 1));

      // And the older page is there above them.
      await tester.scrollUntilVisible(
        text('turn 140'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(text('turn 140'), findsWidgets);
    });

    testWidgets('while the last message streams below', (tester) async {
      size(tester, const Size(1200, 900));
      await tester.pumpWidget(view(conversation(60, last: 'partial')));
      await tester.pump();
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent - 200);
      await tester.pump();
      final anchor = text('turn 55').first;
      final before = tester.getTopLeft(anchor);
      for (var i = 1; i <= 10; i++) {
        await tester.pumpWidget(
          view(conversation(60, last: 'partial${'\nmore' * i * 5}')),
        );
        await tester.pump();
      }
      expect(tester.getTopLeft(anchor), before);
      expect(find.byTooltip('Jump to latest'), findsOneWidget);

      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pump();
      await tester.pump();
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);
    });

    testWidgets('and at the bottom it follows the stream', (tester) async {
      size(tester, const Size(1200, 900));
      await tester.pumpWidget(view(conversation(60, last: 'partial')));
      await tester.pump();
      for (var i = 1; i <= 5; i++) {
        await tester.pumpWidget(
          view(conversation(60, last: 'partial${'\nmore' * i * 10}')),
        );
        await tester.pump();
      }
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);
      expect(find.byTooltip('Jump to latest'), findsNothing);
    });
  });

  group('long things fold', () {
    testWidgets('a long code fence, with its language and a copy', (
      tester,
    ) async {
      size(tester, const Size(1200, 900));
      final code = List.generate(100, (i) => 'final v$i = $i;').join('\n');
      await tester.pumpWidget(
        view([ChatMessage(role: 'agent', text: '```dart\n$code\n```')]),
      );
      await tester.pump();
      expect(find.text('dart'), findsOneWidget);
      expect(find.text('Show all (100 lines)'), findsOneWidget);
      expect(text('final v99'), findsNothing);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.tap(find.byTooltip('Copy code'));
      await tester.pump();
      expect(copied, code);

      await tester.tap(find.text('Show all (100 lines)'));
      await tester.pump();
      expect(text('final v99'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a very long message', (tester) async {
      size(tester, const Size(1200, 900));
      final long = List.generate(500, (i) => 'line $i').join('\n\n');
      await tester.pumpWidget(view([ChatMessage(role: 'agent', text: long)]));
      await tester.pump();
      expect(find.text('Show all (999 lines)'), findsOneWidget);
      expect(text('line 499'), findsNothing);
    });

    testWidgets('a change to many files', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: FileEditDiffs(
                edits: [
                  for (var i = 0; i < 12; i++)
                    FileEditRecord(
                      path: '/repo/file$i.dart',
                      kind: FileEditKind.created,
                      newText: 'x',
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Show 7 more files'), findsOneWidget);
      expect(text('file11.dart'), findsNothing);
      await tester.tap(find.text('Show 7 more files'));
      await tester.pump();
      expect(text('file11.dart'), findsWidgets);
    });
  });

  test('a turn copies from the prompt to the last row before the next', () {
    const messages = [
      ChatMessage(role: 'user', text: 'first'),
      ChatMessage(role: 'agent', text: 'one'),
      ChatMessage(role: 'user', text: 'second'),
      ChatMessage(
        role: 'tool',
        text: '',
        tool: ToolActivity(name: 'Bash', subject: 'ls', output: 'a.txt'),
      ),
      ChatMessage(role: 'agent', text: 'done'),
      ChatMessage(role: 'user', text: 'third'),
    ];
    expect(
      transcriptTurnText(messages, 4),
      'You:\nsecond\n\n› Bash\nls\na.txt\n\ndone',
    );
    expect(transcriptTurnText(messages, 1), 'You:\nfirst\n\none');
  });

  group('wide content never overflows the page', () {
    final header = List.generate(12, (i) => 'column$i').join(' | ');
    final rule = List.filled(12, '---').join(' | ');
    final row = List.generate(12, (i) => 'value-number-$i').join(' | ');
    final messages = [
      const ChatMessage(role: 'user', text: 'show me'),
      ChatMessage(
        role: 'agent',
        text:
            '| $header |\n| $rule |\n| $row |\n\n'
            '```\n${'x' * 600}\n```\n\n'
            '${'averyveryverylongwordwithoutanybreaks' * 8}\n\n'
            '- [x] done\n- [ ] todo\n  1. nested\n     - deeper\n\n'
            'A note[^1].\n\n[^1]: The note.\n\n<b>escaped</b>',
      ),
    ];
    for (final width in const [360.0, 390.0, 1440.0]) {
      for (final scale in const [1.0, 1.6]) {
        for (final brightness in Brightness.values) {
          testWidgets('$width px, text ×$scale, ${brightness.name}', (
            tester,
          ) async {
            size(tester, Size(width, 900));
            await tester.pumpWidget(
              view(messages, brightness: brightness, textScale: scale),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(text('<b>escaped</b>'), findsOneWidget);
          });
        }
      }
    }
  });
}
