import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// **A context's colour is identity, and it has to be seen.** Every hue keeps
/// WCAG 3:1 — the floor for a graphic — against the band a header rests on
/// and the pane surface a chip rests on, in both themes, and sits well away
/// from the hues that mean something.
void main() {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();

  double luminance(Color color) =>
      0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);

  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  for (final (theme, brightness) in [
    (AppTheme.light(), Brightness.light),
    (AppTheme.dark(), Brightness.dark),
  ]) {
    final scheme = theme.colorScheme;
    final surfaces = {
      'band': ExplorerRow.bandColor(scheme),
      'pane': scheme.surface,
      'selected chip': Color.alphaBlend(
        StateLayers.selected(scheme),
        scheme.surface,
      ),
    };
    test('${brightness.name}: every hue is 3:1 against the band, the pane and '
        'a selected chip', () {
      for (final hue in ContextHue.values) {
        for (final entry in surfaces.entries) {
          final ratio = contrast(hue.of(brightness), entry.value);
          expect(
            ratio,
            greaterThanOrEqualTo(3),
            reason:
                '${hue.name} on the ${entry.key} in ${brightness.name}: '
                '${ratio.toStringAsFixed(2)}:1',
          );
        }
      }
    });

    double degrees(Color color) => HSLColor.fromColor(color).hue;
    double apart(double a, double b) {
      final d = (a - b).abs() % 360;
      return d > 180 ? 360 - d : d;
    }

    test('${brightness.name}: no hue is within 20° of a status colour', () {
      final semantic = SemanticColors.forBrightness(brightness);
      // Not "working": that is the accent's spinner (spec §2.3), and the
      // accent is not reserved.
      final reserved = {
        'idle': semantic.idle,
        'attention': semantic.attention,
        'failure': semantic.failure,
        'unread': semantic.unread,
      };
      for (final hue in ContextHue.values) {
        for (final entry in reserved.entries) {
          final gap = apart(degrees(hue.of(brightness)), degrees(entry.value));
          expect(
            gap,
            greaterThanOrEqualTo(20),
            reason:
                '${hue.name} is ${gap.toStringAsFixed(0)}° from '
                '${entry.key} in ${brightness.name}',
          );
        }
      }
    });

    test('${brightness.name}: the hues keep 24° from each other', () {
      for (final a in ContextHue.values) {
        for (final b in ContextHue.values) {
          if (a.index >= b.index) continue;
          final gap = apart(
            degrees(a.of(brightness)),
            degrees(b.of(brightness)),
          );
          expect(
            gap,
            greaterThanOrEqualTo(24),
            reason:
                '${a.name} and ${b.name} are ${gap.toStringAsFixed(0)}° apart '
                'in ${brightness.name}',
          );
        }
      }
    });
  }

  test('the palette is seven hues, stored by name, and an unknown name is no '
      'colour', () {
    expect(ContextHue.values, hasLength(7));
    for (final hue in ContextHue.values) {
      expect(ContextHue.tryParse(hue.name), hue);
      expect(hue.label, isNotEmpty);
    }
    expect(ContextHue.tryParse(null), isNull);
    expect(ContextHue.tryParse('chartreuse'), isNull);
    expect(ContextHue.tryParse(''), isNull);
  });

  testWidgets('the dot takes its theme\'s variant, at the size it is asked '
      'for, and says its colour only when told to', (tester) async {
    for (final (theme, expected) in [
      (AppTheme.light(), ContextHue.teal.light),
      (AppTheme.dark(), ContextHue.teal.dark),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: ContextHueDot(hue: ContextHue.teal, size: 12),
          ),
        ),
      );
      // MaterialApp animates a theme change; the dot reads the settled one.
      await tester.pumpAndSettle();
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ContextHueDot),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, expected);
      expect(decoration.shape, BoxShape.circle);
      expect(tester.getSize(find.byType(ContextHueDot)), const Size(12, 12));
      expect(find.bySemanticsLabel('Teal context'), findsNothing);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: const Scaffold(
          body: ContextHueDot(hue: ContextHue.teal, label: 'Teal context'),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Teal context'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ContextHueDot)),
      const Size(ContextHueDot.headerSize, ContextHueDot.headerSize),
    );
  });
}
