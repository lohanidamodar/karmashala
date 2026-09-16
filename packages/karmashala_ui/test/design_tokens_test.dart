import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// Values that were bare literals at their sites before they were named. The
/// names must not move what was already on screen.
void main() {
  test('a hairline inset is one pixel, under the 4-pt scale', () {
    expect(Insets.hair, 1.0);
    expect(Insets.hair, lessThan(Insets.xs));
  });

  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.dark
        ? AppTheme.dark()
        : AppTheme.light();
    final scheme = theme.colorScheme;

    test('the selection tint is the accent at 14% ($brightness)', () {
      expect(Tints.selection(scheme), scheme.primary.withValues(alpha: 0.14));
    });

    test('the navigation bar indicator wears it under touch ($brightness)', () {
      expect(
        UiDensity.touch.themeFor(theme).navigationBarTheme.indicatorColor,
        Tints.selection(scheme),
      );
    });

    testWidgets('a selected Explorer row is its resting tone under the tint '
        '($brightness)', (tester) async {
      await pumpInBox(
        tester,
        width: 300,
        theme: theme,
        child: ExplorerRow(
          kind: ExplorerRowKind.session,
          depth: 0,
          selected: true,
          builder: (_) => const SizedBox(height: 20),
        ),
      );
      final fills = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(ExplorerRow),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((box) => (box.decoration as BoxDecoration).color)
          .toList();
      final expected = Color.alphaBlend(
        Tints.selection(scheme),
        ExplorerRowKind.session.surface(scheme),
      );
      expect(fills, contains(expected));
    });
  }
}
