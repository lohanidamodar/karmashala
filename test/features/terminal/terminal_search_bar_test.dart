import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/theme/app_theme.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_search_bar.dart';

import 'search_layout.dart';

/// What the find bar actually says, which is the whole point of the two
/// honesty rules this feature is built on: a pattern that will not compile must
/// not read as "not found", and a pane's history vanishing behind a full-screen
/// program must not read as "not there".
void main() {
  late SearchLayout layout;

  setUp(() {
    layout = SearchLayout(
      panes: 2,
      linesPerPane: 3,
      text: (pane, line) => 'pane $pane line $line',
    );
    addTearDown(layout.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: layout.container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: TerminalSearchBar()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a hit reads as a position in a total', (tester) async {
    layout.search
      ..open(layout.panes.first)
      ..setQuery('line 1');
    await pump(tester);

    expect(find.text('1 / 1'), findsOneWidget);
  });

  testWidgets('a broken pattern says so instead of "No results"', (
    tester,
  ) async {
    layout.search
      ..open(layout.panes.first)
      ..toggleRegex()
      ..setQuery('line (');
    await pump(tester);

    expect(find.text('Invalid pattern'), findsOneWidget);
    expect(find.text('No results'), findsNothing);
  });

  testWidgets('a full-screen program says where the rest of the hits went', (
    tester,
  ) async {
    layout.write(layout.panes.first, '\x1b[?1049h');
    layout.search
      ..open(layout.panes.first)
      ..setQuery('line 1');
    await pump(tester);

    expect(find.text('None on screen'), findsOneWidget);
    expect(find.text('+1 behind'), findsOneWidget);
  });

  testWidgets('a hit in another pane is named, and can be jumped to', (
    tester,
  ) async {
    layout.write(layout.panes[1], 'only-over-here\r\n');
    layout.search
      ..open(layout.panes.first)
      ..toggleCrossPane()
      ..setQuery('only-over-here');
    layout.schedule.drain();
    await pump(tester);

    final title = layout.state.currentPaneTitle!;
    expect(find.text(title), findsOneWidget);
    expect(find.text('2 panes'), findsOneWidget);

    await tester.tap(find.text(title));
    await tester.pump();

    // The pane's own FocusNode is not in this tree — only the bar is — so the
    // observable part of the jump is the layout moving to it.
    expect(
      layout.container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .focusedPaneId,
      layout.panes[1],
      reason: 'the button really jumps to the pane the hit came from',
    );
  });
}
