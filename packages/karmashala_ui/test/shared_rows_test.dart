import 'package:agent_cli/read.dart' show kRedactedThinking;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import 'support/layout_probe.dart';

/// Three small rows every area draws: the reasoning accordion's header, the
/// two-line menu row, and the pane header. Each had one child that could not
/// give way, or a height that did not follow the text.
void main() {
  group('ThinkingAccordion', () {
    const thinking = 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine';

    testWidgets('redacted thinking is a small marker that opens to nothing', (
      tester,
    ) async {
      await pumpInBox(
        tester,
        width: 320,
        child: const ThinkingAccordion(thinking: kRedactedThinking),
      );
      expect(find.text('Thinking (redacted)'), findsOneWidget);
      expect(find.textContaining('Thought'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    for (final width in [200.0, 240.0]) {
      for (final scale in sweepScales) {
        testWidgets('its header fits ${width.toInt()}px at ${scale}x', (
          tester,
        ) async {
          final overflows = await pumpInBox(
            tester,
            width: width,
            textScale: scale,
            child: const ThinkingAccordion(thinking: thinking),
          );
          expect(overflows, isEmpty);
        });
      }
    }

    testWidgets('a thumb gets a whole target, a pointer keeps the dense row', (
      tester,
    ) async {
      Future<double> headerHeight(UiDensity density) async {
        await pumpInBox(
          tester,
          width: 320,
          density: density,
          child: const ThinkingAccordion(thinking: thinking),
        );
        return tester.getSize(find.byType(InkWell)).height;
      }

      expect(await headerHeight(UiDensity.touch), Touch.target);
      expect(await headerHeight(UiDensity.pointer), lessThan(Touch.target));

      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.textContaining('nine'), findsOneWidget);
    });
  });

  group('DesktopMenuDetailRow', () {
    Widget row() => const DesktopMenuDetailRow(
      label: 'claude-opus-with-a-rather-long-model-name',
      detail: 'The most capable model, for the hardest work.',
      icon: AppIcons.robot,
      badge: 'approximate, and not enforced by the agent',
    );

    for (final width in [200.0, 240.0, 320.0]) {
      for (final scale in sweepScales) {
        testWidgets('a long label and badge fit ${width.toInt()}px at '
            '${scale}x', (tester) async {
          final overflows = await pumpInBox(
            tester,
            width: width,
            textScale: scale,
            child: row(),
          );
          expect(overflows, isEmpty);
          expect(
            find.text('approximate, and not enforced by the agent'),
            findsOneWidget,
          );
        });
      }
    }

    testWidgets(
      'still measures inside a popup menu, which sizes by intrinsics',
      (tester) async {
        final overflows = await pumpInBox(
          tester,
          width: 400,
          child: Center(child: IntrinsicWidth(child: row())),
        );
        expect(overflows, isEmpty);
      },
    );
  });

  group('PaneHeader', () {
    Widget header() => PaneCloseAction(
      tooltip: 'Close panel',
      onClose: () {},
      child: const PaneHeader(title: 'Changes', icon: AppIcons.gitDiff),
    );

    testWidgets('is one tab-strip row at the default text size', (
      tester,
    ) async {
      await pumpInBox(tester, width: 240, child: header());
      expect(
        tester.getSize(find.byType(PaneHeader)).height,
        Chrome.tabStrip + 1,
      );
    });

    for (final scale in [1.3, 2.0]) {
      testWidgets('grows with ${scale}x text so the title is not clipped', (
        tester,
      ) async {
        final overflows = await pumpInBox(
          tester,
          width: 240,
          textScale: scale,
          child: header(),
        );
        expect(overflows, isEmpty);
        final bar = tester.getSize(find.byType(PaneHeader)).height - 1;
        expect(bar, greaterThan(Chrome.tabStrip));
        expect(
          tester.getSize(find.text('CHANGES')).height,
          lessThanOrEqualTo(bar),
        );
      });
    }

    testWidgets('under touch, the close button keeps its whole target', (
      tester,
    ) async {
      final overflows = await pumpInBox(
        tester,
        width: 320,
        density: UiDensity.touch,
        child: header(),
      );
      expect(overflows, isEmpty);
      final button = tester.getSize(find.byType(IconButton));
      expect(button.width, greaterThanOrEqualTo(Touch.target));
      expect(button.height, greaterThanOrEqualTo(Touch.target));
    });
  });
}
