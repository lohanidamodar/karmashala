import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// The one width-class helper PROJECT.md §6 asks for, and the row that stacks
/// when narrow. Thresholds are §6's 600/840, grown with the text scale.
void main() {
  group('WidthClass.of', () {
    test('uses §6 breakpoints at 1x text', () {
      expect(WidthClass.of(0), WidthClass.compact);
      expect(WidthClass.of(599.9), WidthClass.compact);
      expect(WidthClass.of(600), WidthClass.medium);
      expect(WidthClass.of(839.9), WidthClass.medium);
      expect(WidthClass.of(840), WidthClass.expanded);
      expect(WidthClass.of(2560), WidthClass.expanded);
    });

    test('shares its compact breakpoint with UiDensity', () {
      expect(WidthClass.mediumMin, UiDensity.compactWidth);
      expect(WidthClass.expandedMin, 840);
    });

    test('grows the breakpoints with the text scale', () {
      const doubled = TextScaler.linear(2);
      expect(WidthClass.of(1199, textScaler: doubled), WidthClass.compact);
      expect(WidthClass.of(1200, textScaler: doubled), WidthClass.medium);
      expect(WidthClass.of(1679, textScaler: doubled), WidthClass.medium);
      expect(WidthClass.of(1680, textScaler: doubled), WidthClass.expanded);

      const larger = TextScaler.linear(1.3);
      expect(WidthClass.of(779, textScaler: larger), WidthClass.compact);
      expect(WidthClass.of(780, textScaler: larger), WidthClass.medium);
    });

    test('never shrinks them for small text', () {
      const smaller = TextScaler.linear(0.8);
      expect(WidthClass.of(599, textScaler: smaller), WidthClass.compact);
      expect(WidthClass.scaleBreakpoint(500, smaller), 500);
    });

    test('says what it is', () {
      expect(WidthClass.compact.isCompact, isTrue);
      expect(WidthClass.medium.isCompact, isFalse);
      expect(WidthClass.expanded.isExpanded, isTrue);
    });
  });

  group('StackWhenNarrow', () {
    Widget row() => const StackWhenNarrow(
      breakpoint: 440,
      leading: Text(
        'Default agent — the one a new session starts with',
        key: ValueKey('leading'),
      ),
      trailing: SizedBox(key: ValueKey('trailing'), width: 160, height: 32),
      trailingMaxWidth: 320,
    );

    Rect rectOf(WidgetTester tester, String key) =>
        tester.getRect(find.byKey(ValueKey(key)));

    testWidgets('side by side at the breakpoint', (tester) async {
      await pumpInBox(tester, width: 440, child: row());
      expect(
        rectOf(tester, 'trailing').left,
        greaterThan(rectOf(tester, 'leading').right),
      );
    });

    testWidgets('stacked below it', (tester) async {
      await pumpInBox(tester, width: 439, child: row());
      expect(
        rectOf(tester, 'trailing').top,
        greaterThanOrEqualTo(rectOf(tester, 'leading').bottom),
      );
    });

    testWidgets('stacked at the same width once the text is larger', (
      tester,
    ) async {
      await pumpInBox(tester, width: 500, textScale: 1.3, child: row());
      expect(
        rectOf(tester, 'trailing').top,
        greaterThanOrEqualTo(rectOf(tester, 'leading').bottom),
      );
    });

    for (final width in [200.0, 320.0, 600.0]) {
      for (final scale in sweepScales) {
        testWidgets('never overflows at ${width.toInt()}px, ${scale}x', (
          tester,
        ) async {
          final overflows = await pumpInBox(
            tester,
            width: width,
            textScale: scale,
            child: row(),
          );
          expect(overflows, isEmpty);
        });
      }
    }
  });
}
