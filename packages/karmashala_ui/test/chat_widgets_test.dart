import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

/// The transcript pieces the desktop and the phone both draw a turn with.
void main() {
  group('splitThinking', () {
    test('lifts a <thinking> or <thought> block out of the turn', () {
      for (final tag in const ['thinking', 'thought']) {
        expect(splitThinking('<$tag> weigh it </$tag>The answer.'), (
          'weigh it',
          'The answer.',
        ), reason: tag);
      }
    });

    test('an explicit field wins and leaves the text as written', () {
      const text = 'literal <thinking>kept</thinking>';
      expect(splitThinking(text, explicit: ' field '), ('field', text));
    });

    test('a blank field falls back to the tags, and no tag is no thinking', () {
      expect(splitThinking('<thought>t</thought>x', explicit: '  '), (
        't',
        'x',
      ));
      expect(splitThinking('plain'), (null, 'plain'));
    });
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double width = 400,
    UiDensity density = UiDensity.pointer,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: UiDensityScope(
          density: density,
          child: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );
  }

  group('TranscriptRoleHeader', () {
    testWidgets('draws the eyebrow upper-case beside its glyph', (
      tester,
    ) async {
      await pump(
        tester,
        const TranscriptRoleHeader(
          icon: AppIcons.robot,
          label: 'Agent',
          color: Colors.black,
          meta: Text('5m'),
        ),
      );
      expect(find.text('AGENT'), findsOneWidget);
      expect(find.text('5m'), findsOneWidget);
      expect(find.byIcon(AppIcons.robot), findsOneWidget);
    });

    testWidgets('sizes come from the caller, and a ring wraps the glyph', (
      tester,
    ) async {
      await pump(
        tester,
        const TranscriptRoleHeader(
          icon: AppIcons.robot,
          label: 'AGENT',
          color: Colors.black,
          ring: Colors.amber,
          iconSize: Touch.iconSmall,
        ),
        density: UiDensity.touch,
      );
      final icon = tester.widget<Icon>(find.byIcon(AppIcons.robot));
      expect(icon.size, Touch.iconSmall);
      expect(
        tester.getSize(
          find.ancestor(
            of: find.byIcon(AppIcons.robot),
            matching: find.byType(Container),
          ),
        ),
        const Size(Touch.iconSmall + Insets.sm, Touch.iconSmall + Insets.sm),
      );

      await pump(
        tester,
        const TranscriptRoleHeader(
          icon: AppIcons.robot,
          label: 'AGENT',
          color: Colors.black,
          ring: Colors.amber,
          ringDiameter: 30,
        ),
      );
      expect(
        tester.getSize(
          find.ancestor(
            of: find.byIcon(AppIcons.robot),
            matching: find.byType(Container),
          ),
        ),
        const Size(30, 30),
      );
    });

    testWidgets('a long unbroken name gives way before the actions do', (
      tester,
    ) async {
      final name = 'mcp__${'x' * 200}';
      await pump(
        tester,
        TranscriptRoleHeader(
          icon: AppIcons.gearSix,
          label: name,
          fullLabel: name,
          color: Colors.black,
          badge: const Text('FAILED'),
          meta: const Text('12m'),
          actions: [
            IconButton(
              tooltip: 'Copy message',
              onPressed: () {},
              icon: const Icon(AppIcons.copySimple),
            ),
          ],
        ),
        width: 160,
      );
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Copy message'), findsOneWidget);
      final copy = tester.getRect(find.byTooltip('Copy message'));
      final header = tester.getRect(find.byType(TranscriptRoleHeader));
      expect(copy.right, lessThanOrEqualTo(header.right + 0.01));
    });
  });

  group('TranscriptTurnFrame', () {
    testWidgets('unframed adds nothing round the turn', (tester) async {
      await pump(
        tester,
        const TranscriptTurnFrame(
          padding: EdgeInsets.all(40),
          child: SizedBox(key: Key('turn'), height: 10),
        ),
      );
      expect(find.byType(DecoratedBox), findsNothing);
      expect(tester.getSize(find.byKey(const Key('turn'))).width, 400);
    });

    testWidgets('framed pads the turn and draws its edge', (tester) async {
      await pump(
        tester,
        const TranscriptTurnFrame(
          fill: Colors.white,
          edge: Colors.red,
          radius: Radii.lg,
          padding: EdgeInsets.all(Insets.md),
          clip: true,
          child: SizedBox(key: Key('turn'), height: 10),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('turn'))).width,
        400 - 2 * Insets.md,
      );
      final box = tester.widget<DecoratedBox>(
        find.ancestor(
          of: find.byKey(const Key('turn')),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.border, Border.all(color: Colors.red));
      expect(decoration.borderRadius, BorderRadius.circular(Radii.lg));
      expect(find.byType(ClipRRect), findsOneWidget);
    });
  });
}
