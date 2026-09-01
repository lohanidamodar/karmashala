import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/terminal/presentation/empty_pane_region.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// The face of an empty split, and the two ways to fill one.
///
/// Splitting starts nothing now, so the new region has to say what it is and
/// offer a way on — and the drag that moves a tab into it needs an equal that
/// works from the keyboard, because a drag-only feature is one some people
/// cannot use at all.
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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a split opens onto an empty state, not a blank rectangle', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);
    controller.splitPane(SplitAxis.horizontal);
    await tester.pump();

    expect(find.byType(EmptyPaneRegion), findsOneWidget);
    expect(find.text('Empty split'), findsOneWidget);
    expect(find.text('New terminal'), findsOneWidget);
  });

  testWidgets('the empty state starts a terminal in that region', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);
    final slot = controller.splitPane(SplitAxis.horizontal)!;
    await tester.pump();
    await tester.tap(find.text('New terminal'));
    await tester.pump();

    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    expect(tab.layout.panes, hasLength(2));
    expect(tab.layout.panes, isNot(contains(slot)));
    for (final paneId in tab.layout.panes) {
      expect(controller.instanceFor(paneId), isNotNull);
    }
    expect(find.byType(EmptyPaneRegion), findsNothing);
  });

  testWidgets('closing the empty region collapses the split', (tester) async {
    final container = workbenchContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);
    controller.splitPane(SplitAxis.horizontal);
    await tester.pump();
    await tester.tap(find.text('Close split'));
    await tester.pump();

    expect(find.byType(EmptyPaneRegion), findsNothing);
    expect(
      container.read(terminalSessionsControllerProvider).activeTab!.layout.panes,
      hasLength(1),
    );
  });

  testWidgets('a tab chip dragged onto the region moves that tab in', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final host = controller.openTab(TerminalProfile.powerShell);
    final kept = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    final moved = controller.openTab(TerminalProfile.commandPrompt);
    final movedPane = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    controller.activateTab(host);

    await pumpWorkbench(tester, container);
    controller.splitPane(SplitAxis.horizontal);
    await tester.pump();

    final chips = find.byType(TerminalTabChip);
    expect(chips, findsNWidgets(2));
    final chip = tester.getCenter(chips.at(_indexOfTab(tester, chips, moved)));
    final gesture = await tester.startGesture(chip);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(EmptyPaneRegion)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, hasLength(1), reason: 'the tab left the strip');
    expect(state.activeTab!.id, host);
    expect(state.activeTab!.layout.panes, [kept, movedPane]);
    expect(find.byType(EmptyPaneRegion), findsNothing);
  });

  testWidgets('"Move a tab here" is offered only when a tab could land', (
    tester,
  ) async {
    final container = workbenchContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);
    controller.splitPane(SplitAxis.horizontal);
    await tester.pump();

    TextButton moveButton() => tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Move a tab here…'),
        matching: find.byType(TextButton),
      ),
    );
    expect(
      moveButton().onPressed,
      isNull,
      reason: 'there is no other tab to move',
    );

    controller.openTab(TerminalProfile.commandPrompt);
    controller.activateTab(
      container.read(terminalSessionsControllerProvider).tabs.first.id,
    );
    await tester.pump();

    expect(moveButton().onPressed, isNotNull);
  });
}

/// Which chip in the strip belongs to [tabId].
///
/// The strip draws tabs in workspace order, so the index is the tab's position
/// — asked rather than assumed, so a reordering elsewhere fails loudly here
/// instead of silently dragging the wrong tab.
int _indexOfTab(WidgetTester tester, Finder chips, String tabId) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(WorkbenchView)),
  );
  final tabs = container.read(terminalSessionsControllerProvider).tabs;
  final index = tabs.indexWhere((tab) => tab.id == tabId);
  expect(index, isNonNegative);
  return index;
}
