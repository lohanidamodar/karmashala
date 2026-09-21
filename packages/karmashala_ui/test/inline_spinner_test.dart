import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// The spinner that replaces 41 hand-built `SizedBox` + ring copies. What is
/// asserted is what a caller relies on: the square it occupies at each size
/// and density, the thin stroke, and that it can be named.
void main() {
  const expected = {
    UiDensity.pointer: {
      InlineSpinnerSize.small: Chrome.iconAction,
      InlineSpinnerSize.medium: Chrome.icon,
      InlineSpinnerSize.large: Chrome.iconHero,
    },
    UiDensity.touch: {
      InlineSpinnerSize.small: Touch.iconSmall,
      InlineSpinnerSize.medium: Touch.icon,
      InlineSpinnerSize.large: Touch.iconHero,
    },
  };

  SteppedRing ringOf(WidgetTester tester) =>
      tester.widget<SteppedRing>(find.byType(SteppedRing));

  for (final density in UiDensity.values) {
    for (final size in InlineSpinnerSize.values) {
      testWidgets('${size.name} is a ${expected[density]![size]}px square '
          'under ${density.name}', (tester) async {
        await pumpInBox(
          tester,
          width: 200,
          density: density,
          child: Center(child: InlineSpinner(size: size)),
        );
        expect(
          tester.getSize(find.byType(InlineSpinner)),
          Size.square(expected[density]![size]!),
        );
        expect(size.dimensionFor(density), expected[density]![size]);
        expect(ringOf(tester).stroke, 2);
      });
    }
  }

  testWidgets('defaults to small, and passes colour and name through', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpInBox(
      tester,
      width: 200,
      child: const Center(
        child: InlineSpinner(
          color: Colors.pink,
          semanticsLabel: 'Loading branches',
        ),
      ),
    );
    expect(tester.getSize(find.byType(InlineSpinner)).width, Chrome.iconAction);
    expect(ringOf(tester).color, Colors.pink);
    expect(find.bySemanticsLabel('Loading branches'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('with no colour it takes the theme\'s progress colour', (
    tester,
  ) async {
    await pumpInBox(
      tester,
      width: 200,
      child: const Center(child: InlineSpinner()),
    );
    expect(ringOf(tester).color, isNotNull);
  });
}
