import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import 'fake_instance.dart';

ProviderContainer workbenchContainer() {
  final database = AppDatabase.memory();
  addTearDown(database.close);
  final container = fakeTerminalContainer(database: database);
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpWorkbench(
  WidgetTester tester,
  ProviderContainer container, {
  Size size = const Size(1200, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
    ),
  );
  await tester.pump();
}

void main() {
  group('TerminalSessionsController split APIs', () {
    test('splitPaneWithTab merges source tab into target pane as a split', () {
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tab1 = controller.openTab(TerminalProfile.powerShell);
      final pane1 = controller.state.tabs.first.focusedPaneId;

      final tab2 = controller.openTab(TerminalProfile.commandPrompt);
      final pane2 = controller.state.tabs.last.focusedPaneId;

      expect(controller.state.tabs.length, 2);
      expect(controller.canSplitPaneWithTab(pane1, tab2), isTrue);
      expect(controller.canSplitPaneWithTab(pane1, tab1), isFalse);

      final success = controller.splitPaneWithTab(
        pane1,
        tab2,
        SplitAxis.horizontal,
      );
      expect(success, isTrue);

      final tabs = controller.state.tabs;
      expect(tabs.length, 1);
      final mergedTab = tabs.single;
      expect(mergedTab.layout.panes, containsAll([pane1, pane2]));
      expect(mergedTab.focusedPaneId, pane2);
      expect(controller.titleForTab(mergedTab.id), 'PowerShell | Command Prompt');
    });

    test('splitPaneWithPane splits panes within same tab', () {
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      controller.openTab(TerminalProfile.powerShell);
      final pane1 = controller.state.tabs.first.focusedPaneId;
      final pane2 = controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.commandPrompt,
      )!;

      expect(controller.canSplitPaneWithPane(pane1, pane2), isTrue);
      expect(controller.canSplitPaneWithPane(pane1, pane1), isFalse);

      final success = controller.splitPaneWithPane(
        pane1,
        pane2,
        SplitAxis.vertical,
        insertBefore: true,
      );
      expect(success, isTrue);

      final tab = controller.state.tabs.single;
      expect(tab.layout.panes, containsAll([pane1, pane2]));
      expect(tab.focusedPaneId, pane2);
    });
  });

  group('Split interactions and tap focus', () {
    testWidgets('tapping a terminal pane updates active focused pane and tab title', (
      tester,
    ) async {
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane1 = controller.state.tabs.first.focusedPaneId;

      final pane2 = controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.commandPrompt,
      )!;

      await pumpWorkbench(tester, container);

      // Initially pane2 was opened and focused.
      expect(controller.state.activeTab!.focusedPaneId, pane2);
      expect(controller.titleForTab(tabId), 'PowerShell | Command Prompt');

      // Tap on pane 1.
      final pane1Finder = find.byWidgetPredicate(
        (w) => w is TerminalPaneView && w.instance.id == pane1,
      );
      expect(pane1Finder, findsOneWidget);
      await tester.tap(pane1Finder);
      await tester.pump();

      // Focusing pane1 should update tab's focusedPaneId.
      expect(controller.state.activeTab!.focusedPaneId, pane1);
      expect(controller.titleForTab(tabId), 'PowerShell | Command Prompt');
    });

    testWidgets('dragging tab over terminal pane shows split overlay and splits', (
      tester,
    ) async {
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tab1 = controller.openTab(TerminalProfile.powerShell);
      final pane1 = controller.state.tabs.first.focusedPaneId;

      controller.openTab(TerminalProfile.commandPrompt);
      final pane2 = controller.state.tabs.last.focusedPaneId;

      controller.activateTab(tab1);

      await pumpWorkbench(tester, container);
      expect(controller.state.tabs.length, 2);

      // Find the tab chips in the workbench tab strip.
      final tabChips = find.byType(TerminalTabChip);
      expect(tabChips, findsNWidgets(2));

      // Drag tab 2 chip onto the right half of pane 1.
      final pane1Finder = find.byWidgetPredicate(
        (w) => w is TerminalPaneView && w.instance.id == pane1,
      );
      final pane1Rect = tester.getRect(pane1Finder);
      final rightHalfTarget = Offset(
        pane1Rect.left + pane1Rect.width * 0.75,
        pane1Rect.center.dy,
      );

      final gesture = await tester.startGesture(tester.getCenter(tabChips.at(1)));
      await tester.pump();
      await gesture.moveTo(rightHalfTarget);
      await tester.pump();

      // Split overlay should be visible.
      expect(find.text('Drop to split'), findsOneWidget);

      // Release drop.
      await gesture.up();
      await tester.pumpAndSettle();

      // Should now be merged into 1 tab with both panes split.
      expect(controller.state.tabs.length, 1);
      expect(controller.state.tabs.single.layout.panes, containsAll([pane1, pane2]));
    });

    testWidgets('holding Ctrl while dragging tab onto another tab splits them', (
      tester,
    ) async {
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      controller.openTab(TerminalProfile.powerShell);
      final pane1 = controller.state.tabs.first.focusedPaneId;

      controller.openTab(TerminalProfile.commandPrompt);
      final pane2 = controller.state.tabs.last.focusedPaneId;

      await pumpWorkbench(tester, container);
      expect(controller.state.tabs.length, 2);

      // Simulate holding Ctrl key.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      final tabChips = find.byType(TerminalTabChip);
      final gesture = await tester.startGesture(tester.getCenter(tabChips.at(1)));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(tabChips.at(0)));
      await tester.pump();

      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      // Tabs should have split into 1 tab.
      expect(controller.state.tabs.length, 1);
      expect(controller.state.tabs.single.layout.panes, containsAll([pane1, pane2]));
    });

    testWidgets('dragging tab without Ctrl reorders tabs (left half inserts before, right half after)', (
      tester,
    ) async {
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tab0 = controller.openTab(TerminalProfile.powerShell);
      final tab1 = controller.openTab(TerminalProfile.commandPrompt);
      final tab2 = controller.openTab(TerminalProfile.posix('/bin/bash'));

      await pumpWorkbench(tester, container);
      expect(controller.state.tabs.map((t) => t.id).toList(), [tab0, tab1, tab2]);

      // Drag tab2 (index 2) to the left half of tab0 (index 0).
      final tabChips = find.byType(TerminalTabChip);
      final tab0Rect = tester.getRect(tabChips.at(0));
      final leftHalfTarget = Offset(
        tab0Rect.left + tab0Rect.width * 0.25,
        tab0Rect.center.dy,
      );

      final gesture = await tester.startGesture(tester.getCenter(tabChips.at(2)));
      await tester.pump();
      await gesture.moveTo(leftHalfTarget);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // tab2 should now be at the front: [tab2, tab0, tab1].
      expect(controller.state.tabs.map((t) => t.id).toList(), [tab2, tab0, tab1]);
    });

    testWidgets('and the right half of a tab puts it after that tab', (
      tester,
    ) async {
      // The other half of the same rule, and the half nothing drove: the drop
      // side has to come from where the *pointer* is, not from where the drag
      // feedback's corner happens to be.
      final container = workbenchContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tab0 = controller.openTab(TerminalProfile.powerShell);
      final tab1 = controller.openTab(TerminalProfile.commandPrompt);
      final tab2 = controller.openTab(TerminalProfile.posix('/bin/bash'));

      await pumpWorkbench(tester, container);

      final tabChips = find.byType(TerminalTabChip);
      final tab2Rect = tester.getRect(tabChips.at(2));
      final rightHalfTarget = Offset(
        tab2Rect.left + tab2Rect.width * 0.9,
        tab2Rect.center.dy,
      );

      final gesture = await tester.startGesture(tester.getCenter(tabChips.at(0)));
      await tester.pump();
      await gesture.moveTo(rightHalfTarget);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.state.tabs.map((t) => t.id).toList(), [tab1, tab2, tab0]);
    });
  });
}
