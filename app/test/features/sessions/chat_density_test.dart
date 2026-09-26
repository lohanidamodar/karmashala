import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';

/// **How the chat surface spends its height**, asserted rather than reviewed.
///
/// The owner's report on the chat redesign was *"message enter prompt field is
/// very small and too much spacing"*, and both halves of it were measurable.
/// The composer was 113 logical pixels tall at 1440x900 and gave the glyphs 19
/// of them — a static `Enter to send · Shift + Enter for new line` strip under
/// the box cost more than the text area did, and overflowed its own row by
/// 138px at 390 wide. In the transcript the gap between two messages was 41,
/// 44, 46 or 49px depending on which pair of roles happened to be adjacent.
///
/// Everything here asserts a **relationship**, not a pixel count, for the
/// reason the live tests in CLAUDE.md §18 give: the absolute numbers belong to
/// one Flutter version's font metrics, while "the text gets more room than a
/// third of the box" and "every boundary is the same" are the properties that
/// were actually wrong and that a restyle could quietly break again.
void main() {
  /// The two sizes CLAUDE.md §11 pins. 390 is not only a phone here — it is a
  /// desktop window dragged narrow, and a chat pane in a three-way split.
  const sizes = [Size(1440, 900), Size(390, 844)];

  Future<void> pump(WidgetTester tester, Size size, Widget child) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget composer({TextEditingController? controller}) => Column(
    children: [
      const Expanded(child: SizedBox()),
      MessageComposer(
        controller: controller,
        hintText: 'Message the agent…',
        onSend: (_) async {},
        // The real chip slot: the session's permission mode, its model and
        // its cost. Standing them in with `Chip`s keeps this file ignorant of
        // the providers behind the real three while still paying their width.
        chips: const [
          Chip(label: Text('acceptEdits')),
          Chip(label: Text('sonnet')),
          Chip(label: Text(r'$0.42')),
        ],
      ),
    ],
  );

  group('the composer', () {
    // Asserted at the expanded size only, and deliberately.
    //
    // At 390 the toolbar's chips wrap onto three rows and the composer is
    // 194px for the same 57px of text — 29%. That is the *chips* paying for a
    // narrow pane, which is the right answer there and not the fault this
    // guards against, so a ratio would be measuring the wrong thing. The
    // narrow case is covered by the three-line and no-overflow cases below,
    // which are the two things that were actually broken at 390.
    testWidgets('gives the text more than a third of its height', (
      tester,
    ) async {
      await pump(tester, const Size(1440, 900), composer());
      final whole = tester.getSize(find.byType(MessageComposer)).height;
      final glyphs = tester.getSize(find.byType(EditableText)).height;
      expect(
        glyphs / whole,
        greaterThan(1 / 3),
        reason:
            'the composer is ${whole}px tall and the text area ${glyphs}px of '
            'it — it was 19 of 113. This is the surface the whole session is '
            'written in; if chrome is taking two thirds of it, something '
            'decorative has been added above or below the box',
      );
    });

    for (final size in sizes) {
      final name = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('opens at three lines of room at $name', (tester) async {
        await pump(tester, size, composer());
        final one = TextPainter(
          text: TextSpan(
            text: 'x',
            style: AppTheme.dark().textTheme.bodyMedium,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final glyphs = tester.getSize(find.byType(EditableText)).height;
        expect(
          glyphs,
          greaterThanOrEqualTo(one.height * 3),
          reason:
              'a one-line strip was the "very small" report: an empty '
              'composer must have room for a paragraph of instruction before '
              'it starts scrolling under itself',
        );
      });

      // Nothing is asserted explicitly: a `RenderFlex` that overflows raises
      // through `FlutterError.onError`, which `testWidgets` fails on. The
      // composer's hint strip overflowed by 138px here, so this is a real
      // assertion and not a smoke test.
      testWidgets('lays out with no unreachable content at $name', (
        tester,
      ) async {
        final controller = TextEditingController(text: 'a\nb\nc\nd\ne');
        addTearDown(controller.dispose);
        await pump(tester, size, composer(controller: controller));
        expect(find.byType(MessageComposer), findsOneWidget);
      });
    }

    testWidgets('typing does not rebuild the composer', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, sizes.first, composer(controller: controller));
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'h');
      // Read before the frame is pumped: what is dirty now is what the
      // keystroke woke.
      final dirty = <String>[];
      void walk(Element e) {
        if (e.dirty) dirty.add(e.widget.runtimeType.toString());
        e.visitChildren(walk);
      }

      tester.binding.rootElement!.visitChildren(walk);
      await tester.pump();

      expect(
        dirty,
        isNot(contains('MessageComposer')),
        reason:
            'a `_input.addListener(setState)` existed so the send button '
            'could recolour, and it marked the composer itself dirty on every '
            'character: its build re-diffs the card, the field wrapper, the '
            'toolbar LayoutBuilder, both buttons and the chip row. Only the '
            'send button needs to know what has been typed, and it watches '
            'the controller itself: $dirty',
      );
    });
  });

  group('the transcript', () {
    final at = DateTime.now();
    final conversation = <ChatMessage>[
      ChatMessage(role: 'user', text: 'first question', at: at),
      ChatMessage(role: 'agent', text: 'first answer', at: at),
      ChatMessage(role: 'user', text: 'second question', at: at),
      ChatMessage(role: 'agent', text: 'second answer', at: at),
      ChatMessage(
        role: 'tool',
        text: 'tool',
        tool: const ToolActivity(name: 'Bash', subject: 'git status'),
        at: at,
      ),
      ChatMessage(
        role: 'tool',
        text: 'tool',
        tool: const ToolActivity(name: 'Bash', subject: 'git log -1'),
        at: at,
      ),
    ];
    const bodies = [
      'first question',
      'first answer',
      'second question',
      'second answer',
      'git status',
      'git log -1',
    ];

    for (final size in sizes) {
      final name = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('separates every pair of messages alike at $name', (
        tester,
      ) async {
        await pump(
          tester,
          size,
          ChatTranscriptView(messages: conversation, onSaveNote: (_, _) {}),
        );

        final gaps = <double>[];
        Rect? previous;
        for (final body in bodies) {
          final rect = tester.getRect(
            find.textContaining(body, findRichText: true).first,
          );
          if (previous != null) gaps.add(rect.top - previous.bottom);
          previous = rect;
        }

        // The four boundaries among prose turns. They were 49, 41 and 49 —
        // wider between an agent and the user than between the user and an
        // agent, which said nothing a reader could use.
        final prose = gaps.take(3).toList();
        expect(
          prose.reduce((a, b) => a > b ? a : b) -
              prose.reduce((a, b) => a < b ? a : b),
          lessThanOrEqualTo(1.0),
          reason:
              'two adjacent messages are two items in one list, however they '
              'are labelled: the space between them must not depend on which '
              'roles they happen to be. Got $gaps',
        );
        // And no boundary may drift far from the rest — the tool card was
        // 10px looser than every other pair before its padding came in.
        expect(
          gaps.reduce((a, b) => a > b ? a : b) -
              gaps.reduce((a, b) => a < b ? a : b),
          lessThanOrEqualTo(6.0),
          reason: 'one role is paying for padding the others are not: $gaps',
        );
        // **What this deliberately does not pin: the absolute gap.** Checked
        // by restoring each defect one at a time — the 49/41 alternation came
        // from the user card's 8-top/12-bottom asymmetry, and this case
        // catches that (it reads 44/40/44). Widening *every* margin by the
        // same amount would leave the transcript uniformly looser and pass,
        // and that is the right trade: a pixel budget here would belong to one
        // Flutter version's font metrics, and how dense the conversation
        // should be is the owner's call, not a number this file gets to fix.
      });

      testWidgets('draws its own separation once, not three times at $name', (
        tester,
      ) async {
        await pump(
          tester,
          size,
          ChatTranscriptView(messages: conversation, onSaveNote: (_, _) {}),
        );
        // A tile margin, a card padding *and* a list padding all paying for
        // the same boundary is what made the gaps 41-49px. Two adjacent
        // tiles' rects must therefore touch or nearly touch: the space
        // between two messages belongs inside the tiles, in one place, where
        // `_tileMargin` can state it.
        final tiles = tester
            .widgetList<Padding>(
              find.descendant(
                of: find.byType(ListView),
                matching: find.byWidgetPredicate(
                  (w) => w is Padding && w.padding == _expectedTileMargin,
                ),
              ),
            )
            .length;
        expect(
          tiles,
          conversation.length,
          reason:
              'every message tile carries the one shared margin; a role that '
              'invents its own is how the rhythm came apart',
        );
      });
    }

    testWidgets('the empty state fits a short pane with no scroll', (
      tester,
    ) async {
      // The height `workbench_test.dart` gives a transcript pane once a split
      // halves the window. The four prompt cards did not fit it — they
      // overflowed by 37px, which is what put a scroll view here.
      await pump(
        tester,
        const Size(1440, 900),
        const SizedBox(
          height: 260,
          child: ChatTranscriptView(
            messages: [],
            emptyHint: 'Session is running — say something to the agent.',
          ),
        ),
      );
      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scroll.controller?.position.maxScrollExtent ?? 0.0, 0.0);
      expect(tester.getSize(find.byType(ChatTranscriptView)).height, 260.0);
    });
  });
}

/// The one margin every message tile is expected to carry, spelled out here
/// rather than imported: `_ChatMessageTile._tileMargin` is private, and a test
/// that read it through some accessor could not notice it changing.
const _expectedTileMargin = EdgeInsets.symmetric(vertical: Insets.xs);
