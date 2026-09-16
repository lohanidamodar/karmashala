import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';

import 'support/layout_probe.dart';

/// An empty state in a pane smaller than itself. It used to be a bare Column:
/// in a 240px side panel at 1.3x it overflowed by 100px and pushed its only
/// action ("Attach by address") out of reach.
void main() {
  const message =
      'Nothing is attached yet. Start the app from a terminal with the VM '
      'service enabled, or paste the address it printed to attach to it.';

  for (final scale in sweepScales) {
    testWidgets('scrolls instead of overflowing in 240x200 at ${scale}x', (
      tester,
    ) async {
      var pressed = 0;
      final overflows = await pumpInBox(
        tester,
        width: 240,
        height: 200,
        textScale: scale,
        child: PanePlaceholder(
          message: message,
          icon: AppIcons.folder,
          action: FilledButton(
            onPressed: () => pressed++,
            child: const Text('Attach by address'),
          ),
        ),
      );
      expect(overflows, isEmpty);

      final action = find.text('Attach by address');
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      expect(pressed, 1, reason: 'the way out is reachable by scrolling');
    });
  }

  testWidgets('stays centred when it fits', (tester) async {
    await pumpInBox(
      tester,
      width: 600,
      height: 500,
      child: const PanePlaceholder(message: 'Nothing.'),
    );
    final box = tester.getRect(find.text('Nothing.'));
    expect(box.center.dx, moreOrLessEquals(300, epsilon: 0.5));
    expect(box.center.dy, moreOrLessEquals(250, epsilon: 0.5));
  });

  testWidgets('still lays out with no height bound', (tester) async {
    final overflows = await pumpInBox(
      tester,
      width: 300,
      child: const SingleChildScrollView(
        child: PanePlaceholder(message: 'Nothing.'),
      ),
    );
    expect(overflows, isEmpty);
    expect(find.text('Nothing.'), findsOneWidget);
  });
}
