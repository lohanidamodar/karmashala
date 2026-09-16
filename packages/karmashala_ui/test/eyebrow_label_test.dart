import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/theme.dart';

import 'support/layout_probe.dart';

/// The small spaced uppercase label over a section. Five private copies wrote
/// `Text(label.toUpperCase(), style: labelSmall)` by hand.
void main() {
  testWidgets('is the text uppercased, in the theme label style', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 300,
      child: const EyebrowLabel('Recent commits'),
    );
    final text = tester.widget<Text>(find.text('RECENT COMMITS'));
    final theme = AppTheme.light();
    expect(text.style, theme.textTheme.labelSmall);
    expect(text.maxLines, isNull, reason: 'wraps unless asked not to');
  });

  testWidgets('takes a colour, a line cap and padding', (tester) async {
    await pumpInBox(
      tester,
      width: 300,
      child: const EyebrowLabel(
        'Section',
        color: Color(0xFF123456),
        maxLines: 1,
        padding: EdgeInsets.only(bottom: 8),
      ),
    );
    final text = tester.widget<Text>(find.text('SECTION'));
    expect(text.style?.color, const Color(0xFF123456));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(
      tester.getSize(find.byType(EyebrowLabel)).height,
      tester.getSize(find.text('SECTION')).height + 8,
    );
  });

  for (final scale in sweepScales) {
    testWidgets('a one-line label ellipsises at 80px, ${scale}x', (
      tester,
    ) async {
      final overflows = await pumpInBox(
        tester,
        width: 80,
        textScale: scale,
        child: const EyebrowLabel(
          'What will be sent to the session',
          maxLines: 1,
        ),
      );
      expect(overflows, isEmpty);
    });
  }
}
