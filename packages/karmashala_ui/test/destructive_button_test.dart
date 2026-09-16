import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import 'support/layout_probe.dart';

/// The confirm button of a destructive dialog, copied twelve times as a
/// `FilledButton` restyled in the error colours.
void main() {
  Color? fill(WidgetTester tester) => tester
      .widget<Material>(
        find.descendant(
          of: find.byType(DestructiveButton),
          matching: find.byType(Material),
        ),
      )
      .color;

  testWidgets('is a filled button in the error colours, and presses', (
    tester,
  ) async {
    var pressed = 0;
    await pumpInBox(
      tester,
      width: 300,
      child: Center(
        child: DestructiveButton(
          onPressed: () => pressed++,
          child: const Text('Delete'),
        ),
      ),
    );
    final scheme = AppTheme.light().colorScheme;
    expect(fill(tester), scheme.error);
    final label = tester.widget<RichText>(
      find.descendant(of: find.text('Delete'), matching: find.byType(RichText)),
    );
    expect(label.text.style?.color, scheme.onError);

    await tester.tap(find.byType(DestructiveButton));
    expect(pressed, 1);
  });

  testWidgets('draws the icon beside the label when given one', (tester) async {
    await pumpInBox(
      tester,
      width: 300,
      child: Center(
        child: DestructiveButton(
          onPressed: () {},
          icon: const Icon(AppIcons.trash),
          child: const Text('Delete'),
        ),
      ),
    );
    final icon = tester.getRect(find.byType(Icon));
    final label = tester.getRect(find.text('Delete'));
    expect(icon.right, lessThanOrEqualTo(label.left));
  });

  testWidgets('a null onPressed is disabled, not red', (tester) async {
    await pumpInBox(
      tester,
      width: 300,
      child: const Center(
        child: DestructiveButton(onPressed: null, child: Text('Delete')),
      ),
    );
    expect(fill(tester), isNot(AppTheme.light().colorScheme.error));
  });

  testWidgets('keeps the touch target under touch density', (tester) async {
    await pumpInBox(
      tester,
      width: 300,
      density: UiDensity.touch,
      child: Center(
        child: DestructiveButton(onPressed: () {}, child: const Text('Delete')),
      ),
    );
    expect(
      tester.getSize(find.byType(DestructiveButton)).height,
      greaterThanOrEqualTo(Touch.target),
    );
  });
}
