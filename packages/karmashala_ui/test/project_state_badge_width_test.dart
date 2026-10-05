import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

/// A project line decides what fits from [ProjectStateBadge.widthOf], so the
/// counts must be measured as they are drawn: in tabular figures, which in a
/// proportional font are wider than the plain ones. The test font draws every
/// glyph alike, so the style is what is asserted.
void main() {
  const summary = ProjectSummary(sessions: 6, running: 4, needsAttention: 2);

  for (final inWords in [false, true]) {
    test('every count is measured in tabular figures, '
        '${inWords ? 'in words' : 'bare'}', () {
      final styles = <TextStyle?>[];
      ProjectStateBadge.widthOf(summary, UiDensity.pointer, (text, [style]) {
        styles.add(style);
        return 0;
      }, inWords: inWords);

      expect(styles, hasLength(2));
      for (final style in styles) {
        expect(
          style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
      }
      expect(styles.last?.fontWeight, FontWeight.w600);
    });
  }
}
