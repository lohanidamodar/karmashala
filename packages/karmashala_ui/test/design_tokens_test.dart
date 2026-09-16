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

  test('status surfaces wash their hue: 8% light, 14-16% dark', () {
    final light = SemanticColors.forBrightness(Brightness.light);
    expect(light.attentionSurface, light.attention.withValues(alpha: 0.08));
    expect(light.failureSurface, light.failure.withValues(alpha: 0.08));
    expect(light.workingSurface, light.working.withValues(alpha: 0.08));
    expect(light.unread, const Color(0xFF1F7A3D));

    final dark = SemanticColors.forBrightness(Brightness.dark);
    expect(dark.attentionSurface, dark.attention.withValues(alpha: 0.16));
    expect(dark.failureSurface, dark.failure.withValues(alpha: 0.16));
    expect(dark.workingSurface, dark.working.withValues(alpha: 0.14));
    expect(dark.unread, const Color(0xFF6BCF87));

    // The new roles travel through a theme animation like the old ones.
    expect(light.lerp(dark, 1).unread, dark.unread);
    expect(light.copyWith(unread: dark.unread).unread, dark.unread);
  });

  test('motion durations and curves are the design-direction values', () {
    expect(Motion.instant, Duration.zero);
    expect(Motion.fast, const Duration(milliseconds: 120));
    expect(Motion.base, const Duration(milliseconds: 180));
    expect(Motion.emphasisIn, const Duration(milliseconds: 300));
    expect(Motion.emphasisOut, const Duration(milliseconds: 200));
    expect(Motion.statusPeriod, const Duration(milliseconds: 1000));
    expect(Motion.statusSteps, 12);
    expect(Motion.standard, const Cubic(0.4, 0, 0.2, 1));
    expect(Motion.enter, const Cubic(0.16, 1, 0.3, 1));
    expect(Motion.exit, const Cubic(0.7, 0, 0.84, 0));
  });

  for (final reduced in [false, true]) {
    testWidgets('Motion.of honours reduced motion (reduced: $reduced)', (
      tester,
    ) async {
      late MotionDurations motion;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Builder(
            builder: (context) {
              motion = Motion.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(motion.animate, !reduced);
      final expected = <Duration>[
        Motion.fast,
        Motion.base,
        Motion.emphasisIn,
        Motion.emphasisOut,
        Motion.statusPeriod,
      ].map((d) => reduced ? Duration.zero : d);
      expect(
        [
          motion.fast,
          motion.base,
          motion.emphasisIn,
          motion.emphasisOut,
          motion.statusPeriod,
        ],
        expected.toList(),
      );
      expect(motion.instant, Duration.zero);
    });
  }

  test('the type ramp: a quiet labelSmall, a spaced group label', () {
    final text = AppTheme.light().textTheme;
    expect(text.labelSmall?.fontSize, 11);
    expect(text.labelSmall?.fontWeight, FontWeight.w500);
    expect(text.labelSmall?.letterSpacing, 0.1);
    expect(text.bodyMedium?.height, 1.45);

    expect(Chrome.groupLabel.fontSize, 11);
    expect(Chrome.groupLabel.fontWeight, FontWeight.w600);
    expect(Chrome.groupLabel.letterSpacing, 0.6);
  });

  test('row title and meta, per density', () {
    final theme = AppTheme.light();
    final title = UiDensity.pointer.rowTitle(theme)!;
    expect(title.fontSize, 13);
    expect(title.fontSize! * title.height!, closeTo(18, 0.001));
    expect(title.fontWeight, FontWeight.w500);
    expect(
      UiDensity.pointer.rowTitle(theme, strong: true)!.fontWeight,
      FontWeight.w600,
    );

    final meta = UiDensity.pointer.muted(theme)!;
    expect(meta.fontSize, 11.5);
    expect(meta.fontSize! * meta.height!, closeTo(16, 0.001));
    expect(meta.fontWeight, FontWeight.w400);
    expect(meta.color, theme.colorScheme.onSurfaceVariant);

    // A thumb reads one step up the ramp.
    final touchTitle = UiDensity.touch.rowTitle(theme)!;
    expect(touchTitle.fontSize, theme.textTheme.titleMedium!.fontSize);
    expect(touchTitle.fontWeight, FontWeight.w500);
    expect(
      UiDensity.touch.muted(theme)!.fontSize,
      theme.textTheme.bodySmall!.fontSize,
    );
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
