import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_group_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import '../../support/test_machine.dart';

/// Each region of a split draws its own tab header.
///
/// Without one, a tab dragged into a split was stranded: nothing said what was
/// in the region, and there was no handle to close it or drag it back out. The
/// header is that handle — and the reason a region can hold more than one tab
/// at all.
ProviderContainer workbenchContainer() {
  final database = TestMachine();
  final container = fakeTerminalContainer(machine: database);
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpWorkbench(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        // As `AppShell` builds it. A pane's chords are declared in
        // `shellChords` and dispatched through this widget's `Actions`, so a
        // workbench pumped without it answers no keystroke.
        home: Scaffold(body: ShellShortcuts(child: WorkbenchView())),
      ),
    ),
  );
  await tester.pump();
}

TerminalSessionsController controllerOf(ProviderContainer container) =>
    container.read(terminalSessionsControllerProvider.notifier);

TerminalTab activeTab(ProviderContainer container) =>
    container.read(terminalSessionsControllerProvider).activeTab!;

/// The chip in a region header that names [paneId].
Finder chipFor(String paneId) => find.byKey(PaneTabChip.keyFor(paneId));

void main() {
  testWidgets('a lone pane in a lone region keeps its vertical space', (
    tester,
  ) async {
    final container = workbenchContainer();
    controllerOf(container).openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);

    expect(
      find.byType(PaneGroupStrip),
      findsNothing,
      reason: 'the workbench strip is already this pane\'s header',
    );
  });

  testWidgets('split regions with single panes do not draw inner pane headers', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();

    expect(
      find.byType(PaneGroupStrip),
      findsNothing,
      reason:
          'split regions do not draw redundant inner headers (no headers in two places)',
    );
  });

  testWidgets('a tab moved into a region appears in that region\'s header', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;
    controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab(container).layout.panes.single;
    controller.activateTab(host);

    await pumpWorkbench(tester, container);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );
    await tester.pump();

    // Stack the guest's pane into the left region — a region takes panes.
    controller.movePaneIntoRegion(guestPane, left);
    await tester.pumpAndSettle();

    expect(
      container.read(terminalSessionsControllerProvider).tabs,
      hasLength(1),
      reason: 'the tab left the workbench strip',
    );
    expect(chipFor(left), findsOneWidget);
    expect(chipFor(guestPane), findsOneWidget);
    expect(activeTab(container).layout.groupOf(left)!.panes, [left, guestPane]);
  });

  testWidgets('a split pane can be moved back out to the workbench strip', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;

    await pumpWorkbench(tester, container);
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();

    controller.movePaneToNewTab(right);
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2), reason: 'it is a tab again');
    expect(state.activeTab!.layout.panes, [right]);
    expect(state.tabs.firstWhere((t) => t.layout.contains(left)).layout.panes, [
      left,
    ], reason: 'the region it left goes with it');
  });

  testWidgets('a pane can be moved from one region into another', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;

    await pumpWorkbench(tester, container);
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();
    final third = controller.openInSlot(
      controller.splitPane(SplitAxis.vertical)!,
      TerminalProfile.powerShell,
    )!;
    await tester.pump();
    expect(activeTab(container).layout.groups, hasLength(3));

    controller.movePaneIntoRegion(third, left);
    await tester.pumpAndSettle();

    final layout = activeTab(container).layout;
    expect(layout.groups, hasLength(2));
    expect(layout.groupOf(left)!.panes, [left, third]);
    expect(layout.groupOf(right)!.panes, [right]);
  });

  testWidgets('tapping a header chip brings that pane forward', (tester) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;
    controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab(container).layout.panes.single;
    controller.activateTab(host);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );
    controller.movePaneIntoRegion(guestPane, left);

    await pumpWorkbench(tester, container);
    expect(activeTab(container).layout.groupOf(left)!.activePaneId, guestPane);

    await tester.tap(chipFor(left));
    await tester.pump();

    expect(activeTab(container).layout.groupOf(left)!.activePaneId, left);
    expect(activeTab(container).focusedPaneId, left);
  });

  testWidgets('closing a split pane collapses the split region', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;

    await pumpWorkbench(tester, container);
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();

    controller.closePane(right);
    await tester.pumpAndSettle();

    expect(activeTab(container).layout.panes, [left]);
    expect(
      find.byType(PaneGroupStrip),
      findsNothing,
      reason: 'one region holding one pane needs no header of its own',
    );
  });

  testWidgets(
    'a region header for stacked panes does not look like the workbench strip',
    (tester) async {
      final container = workbenchContainer();
      final controller = controllerOf(container);
      final host = controller.openTab(TerminalProfile.powerShell);
      final left = activeTab(container).layout.panes.single;
      controller.openTab(TerminalProfile.commandPrompt);
      final guestPane = activeTab(container).layout.panes.single;
      controller.activateTab(host);
      controller.movePaneIntoRegion(guestPane, left);

      await pumpWorkbench(tester, container);

      final header = find.byType(PaneGroupStrip).first;
      expect(tester.getSize(header).height, Chrome.paneStrip);
      expect(
        Chrome.paneStrip,
        lessThan(Chrome.tabStrip),
        reason:
            'the row that belongs to a pane is shorter than the row that '
            'belongs to the window',
      );
      expect(
        find.descendant(
          of: header,
          matching: find.byIcon(AppIcons.squareSplitHorizontal),
        ),
        findsOneWidget,
        reason:
            'the same glyph an empty region wears, so both rows of a split '
            'read as region chrome rather than as tabs',
      );
    },
  );

  testWidgets('and the stacked header keeps its shape in the minimum window', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final left = activeTab(container).layout.panes.single;
    controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab(container).layout.panes.single;
    controller.activateTab(host);
    controller.movePaneIntoRegion(guestPane, left);

    await pumpWorkbench(tester, container, size: const Size(720, 560));

    final headers = find.byType(PaneGroupStrip);
    expect(headers, findsOneWidget);
    expect(tester.getSize(headers).height, Chrome.paneStrip);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fresh split does not print the project header on the tab', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = controllerOf(container);
    controller.openTab(
      TerminalProfile.powerShell,
      workingDirectory: r'C:\src\karmashala',
    );
    final pane = activeTab(container).layout.panes.single;
    controller.instanceFor(pane)!.terminal.write('\x1b]2;New session\x07');

    await pumpWorkbench(tester, container);
    controller.splitPane(SplitAxis.horizontal);
    await tester.pump();

    expect(
      find.text('src/karmashala'),
      findsNothing,
      reason: 'the tab does not show a project header on split',
    );
    expect(
      find.text('New session'),
      findsWidgets,
      reason: 'the active focused pane title is shown',
    );
  });

  testWidgets('a chord cycles the panes stacked in the focused region', (
    tester,
  ) async {
    // Alt+Arrow already walks between regions. A pane behind another in the
    // same region has no direction to be in, so it needs a chord of its own —
    // or a stacked tab would be reachable only by clicking its chip.
    final container = workbenchContainer();
    final controller = controllerOf(container);
    final host = controller.openTab(TerminalProfile.powerShell);
    final first = activeTab(container).layout.panes.single;
    controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab(container).layout.panes.single;
    controller.activateTab(host);
    controller.movePaneIntoRegion(guestPane, first);

    await pumpWorkbench(tester, container);
    controller.instanceFor(guestPane)!.focusNode.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(activeTab(container).layout.groups.single.activePaneId, first);
    expect(activeTab(container).focusedPaneId, first);
  });
}
