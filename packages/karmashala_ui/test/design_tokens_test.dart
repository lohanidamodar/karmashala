import 'package:flutter/foundation.dart';
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
    // One amber rest for every needs-you fill: the spec's opaque tone.
    expect(
      SurfaceTones.forBrightness(Brightness.light).attentionSurface,
      const Color(0xFFFBF1DD),
    );
    expect(
      SurfaceTones.forBrightness(Brightness.dark).attentionSurface,
      const Color(0xFF221B10),
    );
    expect(light.failureSurface, light.failure.withValues(alpha: 0.08));
    expect(light.workingSurface, light.working.withValues(alpha: 0.08));
    expect(light.unread, const Color(0xFF1F7A3D));

    final dark = SemanticColors.forBrightness(Brightness.dark);
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
      expect([
        motion.fast,
        motion.base,
        motion.emphasisIn,
        motion.emphasisOut,
        motion.statusPeriod,
      ], expected.toList());
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

  test('the mono stack is a named face per platform, ending in monospace', () {
    expect(monoFamilyFor(TargetPlatform.macOS), 'Menlo');
    expect(monoFallbackFor(TargetPlatform.macOS), ['Monaco', 'monospace']);
    expect(monoFamilyFor(TargetPlatform.windows), 'Cascadia Mono');
    expect(monoFallbackFor(TargetPlatform.windows), ['Consolas', 'monospace']);
    expect(monoFamilyFor(TargetPlatform.linux), 'DejaVu Sans Mono');
    expect(monoFallbackFor(TargetPlatform.linux), [
      'Liberation Mono',
      'monospace',
    ]);
    for (final platform in TargetPlatform.values) {
      expect(monoFallbackFor(platform).last, 'monospace');
    }
  });

  test('MonoStyles and the UI sans follow the running platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(MonoStyles.body.fontFamily, kBundledMonoFamily);
      expect(MonoStyles.body.fontFamilyFallback, [
        'Cascadia Mono',
        'Consolas',
        'monospace',
      ]);
      expect(MonoStyles.body.fontSize, 12);
      expect(AppTheme.light().textTheme.bodyMedium?.fontFamilyFallback, isNull);

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(kMonoFamily, kBundledMonoFamily);
      expect(kMonoFallback.first, 'DejaVu Sans Mono');
      expect(AppTheme.light().textTheme.bodyMedium?.fontFamilyFallback, [
        'Inter',
        'Cantarell',
        'Noto Sans',
      ]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('radii and elevation: a pill, low popups, a floating shadow', () {
    expect(Radii.pill, 999);
    final theme = AppTheme.light();
    expect(theme.popupMenuTheme.elevation, 4);
    expect(theme.menuTheme.style?.elevation?.resolve({}), 4);
    expect(theme.dialogTheme.elevation, 12);
    expect(Shadows.floating, const [
      BoxShadow(
        color: Color.fromRGBO(0, 0, 0, 0.18),
        offset: Offset(0, 10),
        blurRadius: 24,
      ),
    ]);
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

    testWidgets('a selected Explorer row wears the selected layer over a '
        'transparent rest ($brightness)', (tester) async {
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
      // Design direction S3: under a pointer a row rests transparent.
      expect(fills, contains(StateLayers.selected(scheme)));
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
      expect(fill.color, StateLayers.selected(scheme));
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
