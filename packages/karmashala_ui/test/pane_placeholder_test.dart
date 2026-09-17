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

  group('inside a dialog', () {
    Future<List<Object>> openDialog(
      WidgetTester tester,
      PanePlaceholder placeholder,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlertDialog(
              title: const Text('Command snippets'),
              content: SizedBox(width: 520, child: placeholder),
              actions: [
                TextButton(onPressed: () {}, child: const Text('Close')),
              ],
            ),
          ),
        ),
      );
      final errors = <Object>[];
      Object? error;
      while ((error = tester.takeException()) != null) {
        errors.add(error!);
      }
      return errors;
    }

    testWidgets('a filling placeholder stretches the dialog to the window', (
      tester,
    ) async {
      // Why `fillHeight` exists: a pane's empty state takes all the height it
      // is offered, and a dialog offers the whole window.
      final errors = await openDialog(
        tester,
        const PanePlaceholder(message: 'Nothing saved yet.'),
      );
      expect(errors, isEmpty);
      expect(
        tester.getSize(find.byType(PanePlaceholder)).height,
        greaterThan(400),
      );
    });

    testWidgets('fillHeight: false lays out at its own height', (tester) async {
      final errors = await openDialog(
        tester,
        const PanePlaceholder(
          message: 'Nothing saved yet.',
          icon: AppIcons.folder,
          fillHeight: false,
        ),
      );
      expect(errors, isEmpty);
      final placeholder = tester.getRect(find.byType(PanePlaceholder));
      expect(placeholder.width, 520);
      expect(placeholder.height, lessThan(200));
      expect(
        tester.getCenter(find.text('Nothing saved yet.')).dx,
        moreOrLessEquals(placeholder.center.dx, epsilon: 0.5),
      );
    });

    for (final scale in sweepScales) {
      testWidgets('fillHeight: false fits 240px wide at ${scale}x', (
        tester,
      ) async {
        final overflows = await pumpInBox(
          tester,
          width: 240,
          textScale: scale,
          child: const SingleChildScrollView(
            child: PanePlaceholder(
              message:
                  'Nothing saved yet. A snippet is a command you keep so you '
                  'can pick it instead of retyping it.',
              fillHeight: false,
            ),
          ),
        );
        expect(overflows, isEmpty);
      });
    }
  });

  group('the one-line form', () {
    testWidgets('sets the glyph beside a sentence that starts a column', (
      tester,
    ) async {
      await pumpInBox(
        tester,
        width: 320,
        child: const SingleChildScrollView(
          child: PanePlaceholder.inline(
            message: 'No device connected.',
            icon: AppIcons.folder,
          ),
        ),
      );
      final glyph = tester.getRect(find.byIcon(AppIcons.folder));
      final words = tester.getRect(find.text('No device connected.'));
      expect(tester.widget<Icon>(find.byIcon(AppIcons.folder)).size, 16);
      expect(glyph.left, 12);
      expect(words.left, greaterThan(glyph.right));
      expect(words.top, lessThan(glyph.bottom), reason: 'beside, not under');
      expect(tester.getSize(find.byType(PanePlaceholder)).height, lessThan(48));
    });

    for (final scale in sweepScales) {
      testWidgets('fits 240px wide at ${scale}x', (tester) async {
        final overflows = await pumpInBox(
          tester,
          width: 240,
          textScale: scale,
          child: const SingleChildScrollView(
            child: PanePlaceholder.inline(
              message:
                  'No device connected. Plug one in, pair one over Wi-Fi from '
                  'the toolbar, or start one below.',
              icon: AppIcons.folder,
            ),
          ),
        );
        expect(overflows, isEmpty);
      });
    }
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
