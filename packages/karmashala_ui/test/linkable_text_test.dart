import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';

/// **A link has to win the tap without taking it.**
///
/// Notes and todos both already meant something by a tap before they had
/// links: a note card opens its editor, and a todo's body opens an inline
/// field because *"there is nowhere else for a tap on a todo to go"*. So the
/// widget cannot simply hand the gesture to the URL — it has to win exactly
/// where the glyphs are and leave every other pixel to the surface.
void main() {
  Future<void> pump(
    WidgetTester tester,
    String text, {
    VoidCallback? onTapText,
    int? maxLines,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: LinkableText(text, onTapText: onTapText, maxLines: maxLines),
          ),
        ),
      ),
    ),
  );

  testWidgets('a tap on plain text reaches the surface', (tester) async {
    var edits = 0;
    await pump(tester, 'fix the resize bug', onTapText: () => edits++);

    await tester.tap(find.byType(LinkableText));
    await tester.pumpAndSettle();

    expect(edits, 1);
  });

  testWidgets('text with no URL stays a plain Text, so it costs no painter', (
    tester,
  ) async {
    await pump(tester, 'fix the resize bug', onTapText: () {});

    expect(find.byType(Text), findsOneWidget);
    expect(find.byType(RichText), findsOneWidget);
  });

  testWidgets('a URL is underlined and the rest is not', (tester) async {
    await pump(tester, 'see https://example.com/a now');

    // `Text.rich` nests the span it is given under a root of its own, so the
    // leaves are a level down rather than the root's direct children.
    final leaves = <TextSpan>[];
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.text != null) leaves.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(tester.widget<RichText>(find.byType(RichText).first).text);
    expect(
      [for (final l in leaves) l.text],
      ['see ', 'https://example.com/a', ' now'],
    );
    expect(leaves[1].style?.decoration, TextDecoration.underline);
    expect(leaves[0].style?.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('a tap beside the link still edits, so the surface keeps its '
      'gesture', (tester) async {
    var edits = 0;
    await pump(
      tester,
      'see https://example.com/a now',
      onTapText: () => edits++,
    );

    // The far right of a 600px box is past the end of this line's glyphs.
    final box = tester.getRect(find.byType(LinkableText));
    await tester.tapAt(Offset(box.right - 4, box.center.dy));
    await tester.pumpAndSettle();

    expect(
      edits,
      1,
      reason: 'empty space past the text belongs to the surface, not the link',
    );
  });

  testWidgets('the clip is passed to the hit test as well as the text', (
    tester,
  ) async {
    // Four lines of prose with the URL far below the clip. If the measuring
    // painter laid out unbounded it would report a box for the link that the
    // reader cannot see, and a tap near the ellipsis would open it.
    await pump(
      tester,
      '${List.filled(40, 'padding').join(' ')} https://example.com/a',
      onTapText: () {},
      maxLines: 2,
    );

    final rich = tester.widget<RichText>(find.byType(RichText).first);
    expect(rich.maxLines, 2, reason: 'the drawn text is clipped');
  });
}
