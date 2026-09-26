import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_search_bar.dart';
import 'package:karmashala_ui/theme.dart';

import 'search_layout.dart';

/// The find bar is as wide as the focused split, so it has to hold its three
/// navigation controls in a 200px pane at large text.
void main() {
  for (final width in [200.0, 280.0, 360.0, 480.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('find bar fits $width @${scale}x', (tester) async {
        final layout = SearchLayout(panes: 2, linesPerPane: 3);
        addTearDown(layout.dispose);
        layout.write(layout.panes[1], 'only-over-here\r\n');
        layout.search
          ..open(layout.panes.first)
          ..toggleCrossPane()
          ..setQuery('only-over-here');
        layout.schedule.drain();

        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) => errors.add('${details.exception}');
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: layout.container,
              child: MaterialApp(
                theme: AppTheme.dark(),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: const TerminalSearchBar(),
                    ),
                  ),
                ),
              ),
            ),
          );
        } finally {
          FlutterError.onError = previous;
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        }
        expect(errors, isEmpty);

        for (final tooltip in [
          'Previous match (Shift+Enter)',
          'Next match (Enter)',
          'Close find (Esc)',
        ]) {
          final button = find.byTooltip(tooltip);
          expect(button, findsOneWidget, reason: tooltip);
          final rect = tester.getRect(button);
          expect(
            rect.right,
            lessThanOrEqualTo(width + 0.5),
            reason: '$tooltip sits inside the bar',
          );
          expect(
            button.hitTestable(),
            findsOneWidget,
            reason: '$tooltip can be clicked',
          );
        }
      });
    }
  }

  testWidgets('a narrow bar keeps its toggles in a menu', (tester) async {
    final layout = SearchLayout(panes: 2, linesPerPane: 3);
    addTearDown(layout.dispose);
    layout.search.open(layout.panes.first);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: layout.container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 280, child: TerminalSearchBar()),
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Match case'), findsNothing);
    await tester.tap(find.byTooltip('Find options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Match case'));
    await tester.pumpAndSettle();

    expect(layout.state.caseSensitive, isTrue);
  });
}
