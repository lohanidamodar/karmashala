import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/presentation/empty_pane_region.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';

import 'fake_instance.dart';

/// A region can be dragged down to 5% of the window, so its invitation has to
/// fit a small rectangle without hiding the way out.
void main() {
  for (final size in const [Size(200, 180), Size(280, 240), Size(360, 300)]) {
    testWidgets('an empty split fits ${size.width}x${size.height}', (
      tester,
    ) async {
      final database = AppDatabase.memory();
      addTearDown(database.close);
      final container = fakeTerminalContainer(database: database);
      addTearDown(container.dispose);

      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add('${details.exception}');
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox.fromSize(
                    size: size,
                    child: EmptyPaneRegion(
                      paneId: 'slot',
                      focused: false,
                      onNewTerminal: () {},
                      onNewSession: () {},
                      onClose: () {},
                      onMoveTabHere: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      } finally {
        FlutterError.onError = previous;
      }

      expect(errors, isEmpty);
      final region = tester.getRect(find.byType(EmptyPaneRegion));
      for (final label in [
        'Empty split',
        'New terminal',
        'New agent session',
        'Move a pane here…',
        'Close split',
      ]) {
        // A narrow region names its actions in tooltips instead.
        final text = find.text(label);
        final control = text.evaluate().isEmpty ? find.byTooltip(label) : text;
        expect(control.hitTestable(), findsOneWidget, reason: label);
        final rect = tester.getRect(control);
        expect(
          region.left <= rect.left &&
              region.top <= rect.top &&
              rect.right <= region.right &&
              rect.bottom <= region.bottom,
          isTrue,
          reason: '"$label" at $rect is inside the region $region',
        );
      }
      // A region only ever takes panes; a tab is refused on drop.
      expect(find.textContaining('Drag a tab'), findsNothing);
    });
  }
}
