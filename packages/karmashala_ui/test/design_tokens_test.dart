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

    test('state layers are the design-direction values ($brightness)', () {
      expect(
        StateLayers.hover(scheme),
        scheme.onSurface.withValues(alpha: 0.06),
      );
      expect(
        StateLayers.pressed(scheme),
        scheme.onSurface.withValues(alpha: 0.10),
      );
      expect(
        StateLayers.selected(scheme),
        scheme.primary.withValues(alpha: 0.12),
      );
      expect(
        StateLayers.selectedFocused(scheme),
        scheme.primary.withValues(alpha: 0.18),
      );
      expect(
        StateLayers.dropTarget(scheme),
        scheme.primary.withValues(alpha: 0.15),
      );
      expect(
        StateLayers.subtle(scheme),
        scheme.primary.withValues(alpha: 0.08),
      );
      expect(
        StateLayers.textSelection(scheme),
        scheme.primary.withValues(alpha: 0.30),
      );
      expect(
        StateLayers.linkUnderline(scheme),
        scheme.primary.withValues(alpha: 0.40),
      );
      expect(
        StateLayers.focusRing(scheme),
        scheme.primary.withValues(alpha: 0.6),
      );
    });

    test('the theme hovers with the hover layer ($brightness)', () {
      expect(theme.hoverColor, StateLayers.hover(scheme));
      expect(
        theme.listTileTheme.selectedTileColor,
        StateLayers.selected(scheme),
      );
    });

    test('the navigation bar indicator wears it under touch ($brightness)', () {
      expect(
        UiDensity.touch.themeFor(theme).navigationBarTheme.indicatorColor,
        StateLayers.selected(scheme),
      );
    });

    testWidgets('a selected Explorer row is its resting tone under the '
        'selected layer ($brightness)', (tester) async {
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
      final fills = _rowDecorations(tester).map((d) => d.color).toList();
      final expected = Color.alphaBlend(
        StateLayers.selected(scheme),
        ExplorerRowKind.session.surface(scheme),
      );
      expect(fills, contains(expected));
    });

    testWidgets('keyboard focus is an inset ring, not a second fill '
        '($brightness)', (tester) async {
      await pumpInBox(
        tester,
        width: 300,
        theme: theme,
        child: ExplorerRow(
          kind: ExplorerRowKind.session,
          depth: 0,
          selected: true,
          onTap: () {},
          builder: (_) => const SizedBox(height: 20, child: Text('row')),
        ),
      );
      Focus.of(tester.element(find.text('row'))).requestFocus();
      await tester.pumpAndSettle();

      final fill = _rowDecorations(tester).firstWhere((d) => d.border != null);
      expect(
        fill.color,
        Color.alphaBlend(
          StateLayers.selected(scheme),
          ExplorerRowKind.session.surface(scheme),
        ),
      );
      final side = (fill.border! as Border).top;
      expect(side.color, StateLayers.focusRing(scheme));
      expect(side.width, 1.0);
    });
  }
}

List<BoxDecoration> _rowDecorations(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(ExplorerRow),
        matching: find.byType(DecoratedBox),
      ),
    )
    .map((box) => box.decoration)
    .whereType<BoxDecoration>()
    .toList();
