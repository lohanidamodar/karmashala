import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_group_strip.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Each region of a split draws its own tab header.
///
/// Without one, a tab dragged into a split was stranded: nothing said what was
/// in the region, and there was no handle to close it or drag it back out. The
/// header is that handle — and the reason a region can hold more than one tab
/// at all.
ProviderContainer workbenchContainer() {
  final database = AppDatabase.memory();
  addTearDown(database.close);
  final container = fakeTerminalContainer(database: database);
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpWorkbench(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
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

  testWidgets('each region of a split draws a header for its own panes', (
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

    expect(find.byType(PaneGroupStrip), findsNWidgets(2));
    expect(chipFor(left), findsOneWidget);
    expect(chipFor(right), findsOneWidget);
  });

  testWidgets('a tab dragged into a region appears in that region\'s header', (
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

    // The guest is still a workspace tab; drag its chip into the left region.
    final guestChip = find.byType(TerminalTabChip).at(1);
    final gesture = await tester.startGesture(tester.getCenter(guestChip));
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byType(PaneGroupStrip).first),
    );
    await tester.pump();
    await gesture.up();
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

  testWidgets('a pane can be dragged back out to the workbench strip', (
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

    final gesture = await tester.startGesture(
      tester.getCenter(chipFor(right)),
    );
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byType(TerminalTabChip).first),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(2), reason: 'it is a workspace tab again');
    expect(state.activeTab!.layout.panes, [right]);
    expect(
      state.tabs.firstWhere((t) => t.layout.contains(left)).layout.panes,
      [left],
      reason: 'the region it left goes with it',
    );
  });

  testWidgets('a pane can be dragged from one region into another', (
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

    final gesture = await tester.startGesture(
      tester.getCenter(chipFor(third)),
    );
    await tester.pump();
    await gesture.moveTo(tester.getCenter(chipFor(left)));
    await tester.pump();
    await gesture.up();
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
    final guest = controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab(container).layout.panes.single;
    controller.activateTab(host);
    controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.powerShell,
    );
    controller.moveTabIntoSlot(guest, left);

    await pumpWorkbench(tester, container);
    expect(activeTab(container).layout.groupOf(left)!.activePaneId, guestPane);

    await tester.tap(chipFor(left));
    await tester.pump();

    expect(activeTab(container).layout.groupOf(left)!.activePaneId, left);
    expect(activeTab(container).focusedPaneId, left);
  });

  testWidgets('closing the last chip in a region collapses the region', (
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

    await tester.tap(
      find.descendant(of: chipFor(right), matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();

    expect(activeTab(container).layout.panes, [left]);
    expect(
      find.byType(PaneGroupStrip),
      findsNothing,
      reason: 'one region holding one pane needs no header of its own',
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
    final guest = controller.openTab(TerminalProfile.commandPrompt);
    final guestPane = activeTab(container).layout.panes.single;
    controller.activateTab(host);
    controller.moveTabIntoSlot(guest, first);

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
