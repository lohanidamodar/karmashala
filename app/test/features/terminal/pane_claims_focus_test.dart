import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_frame.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_theme_colors.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'fake_instance.dart';
import '../../support/test_machine.dart';

/// **A pane shown away from its tab** — the Agent dashboard's peek — takes
/// clicks and keys without bringing its tab forward; anywhere else a click
/// still makes it the workbench's focused pane.
void main() {
  Future<(ProviderContainer, String, String)> pump(
    WidgetTester tester, {
    required bool claims,
    bool sizesGrid = true,
    double width = 800,
  }) async {
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(machine: TestMachine()),
    );
    addTearDown(container.dispose);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);
    final pane = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == first)
        .layout
        .panes
        .single;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 400,
                child: LiveTerminalPane(
                  paneId: pane,
                  fallback: controller.instanceFor(pane)!,
                  focused: true,
                  fontSize: 14,
                  terminalTheme: terminalThemeFor(ThemeData.dark(), null),
                  chordOverrides: const {},
                  onKeyEvent: (_, _) => KeyEventResult.ignored,
                  onSecondaryTapDown: (_, _) {},
                  claimsPaneFocus: claims,
                  sizesGrid: sizesGrid,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (container, first, second);
  }

  testWidgets('shown away from its tab, a click does not bring it forward', (
    tester,
  ) async {
    final (container, _, second) = await pump(tester, claims: false);
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      second,
    );

    await tester.tapAt(tester.getCenter(find.byType(LiveTerminalPane)));
    await tester.pump();

    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      second,
    );
  });

  testWidgets('in its own place, a click makes it the focused pane', (
    tester,
  ) async {
    final (container, first, _) = await pump(tester, claims: true);

    await tester.tapAt(tester.getCenter(find.byType(LiveTerminalPane)));
    await tester.pump();

    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      first,
    );
  });

  testWidgets('shown away from its tab, it sizes nothing: no reflow fight', (
    tester,
  ) async {
    final (container, first, _) = await pump(
      tester,
      claims: false,
      sizesGrid: false,
      width: 300,
    );
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final pane = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == first)
        .layout
        .panes
        .single;
    final terminal = controller.instanceFor(pane)!.terminal;
    final before = terminal.viewWidth;
    await tester.pump(const Duration(milliseconds: 300));
    expect(terminal.viewWidth, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in its own place it still sizes the grid to its room', (
    tester,
  ) async {
    final (container, first, _) = await pump(tester, claims: true, width: 300);
    final pane = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == first)
        .layout
        .panes
        .single;
    await tester.pump(const Duration(milliseconds: 300));
    final terminal = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(pane)!
        .terminal;
    expect(terminal.viewWidth, lessThan(40));
  });
}
