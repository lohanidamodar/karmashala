import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// A label in a fixed column and a value taking the rest: the verification
/// pane, the repository view and the automation cards each drew one privately.
void main() {
  const long =
      'org.example.a-rather-long-application-identifier.debug.with-flavour';

  for (final width in [200.0, 240.0, 400.0]) {
    for (final scale in sweepScales) {
      testWidgets('fits ${width.toInt()}px at ${scale}x with a trailing '
          'action', (tester) async {
        final overflows = await pumpInBox(
          tester,
          width: width,
          textScale: scale,
          child: LabeledValueRow(
            label: 'Package',
            value: const Text(long),
            trailing: IconButton(
              tooltip: 'Copy',
              onPressed: () {},
              icon: const SizedBox.square(dimension: 16),
            ),
          ),
        );
        expect(overflows, isEmpty);
      });
    }
  }

  testWidgets('the label column is its width and the value starts after it', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 400,
      child: const LabeledValueRow(label: 'Target', value: Text('web')),
    );
    final label = tester.getRect(find.text('Target'));
    final value = tester.getRect(find.text('web'));
    expect(label.width, lessThanOrEqualTo(LabeledValueRow.defaultLabelWidth));
    expect(value.left, LabeledValueRow.defaultLabelWidth);
  });

  testWidgets('the label is muted bodySmall unless given a style', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 400,
      child: const Column(
        children: [
          LabeledValueRow(label: 'Plain', value: Text('a')),
          LabeledValueRow(
            label: 'Styled',
            labelWidth: 80,
            labelStyle: TextStyle(fontWeight: FontWeight.w900),
            padding: EdgeInsets.only(bottom: 2),
            value: Text('b'),
          ),
        ],
      ),
    );
    final theme = AppTheme.light();
    expect(
      tester.widget<Text>(find.text('Plain')).style,
      theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    expect(
      tester.widget<Text>(find.text('Styled')).style?.fontWeight,
      FontWeight.w900,
    );
    expect(tester.getRect(find.text('b')).left, 80);
  });

  testWidgets('pads its bottom by Insets.xs by default', (tester) async {
    await pumpInBox(
      tester,
      width: 400,
      child: const LabeledValueRow(label: 'Id', value: Text('web')),
    );
    expect(
      tester.getSize(find.byType(LabeledValueRow)).height,
      tester.getSize(find.text('web')).height + Insets.xs,
    );
  });
}
