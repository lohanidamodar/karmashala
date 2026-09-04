import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/empty_pane_region.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
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

  testWidgets('the empty state offers a session targeted at that region', (
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
    await tester.tap(find.text('New agent session'));
    await tester.pumpAndSettle();

    expect(find.byType(NewSessionDialog), findsOneWidget);
    expect(find.text('Choose where and how the coding agent should run.'), findsOneWidget);
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

  testWidgets('squeezed to a sliver, it scrolls instead of spilling', (
    tester,
  ) async {
    // A divider can be dragged until a region is 5% of the window
    // (`kMinPaneWeight`), which is narrower than a single button. `Wrap` does
    // not report an overflow the way `Flex` does, so it would quietly paint
    // its buttons outside the region and out of reach — the assertion is that
    // the content becomes scrollable, not merely that nothing threw.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = workbenchContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);

    await pumpWorkbench(tester, container);
    controller.splitPane(SplitAxis.horizontal);
    await tester.pump();

    final sideways = find.descendant(
      of: find.byType(EmptyPaneRegion),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            widget.axisDirection == AxisDirection.right,
      ),
    );
    expect(
      tester.state<ScrollableState>(sideways).position.maxScrollExtent,
      0,
      reason: 'half a desktop window fits it, so there is nothing to scroll',
    );

    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    // Past the clamp on purpose: the region ends up at kMinPaneWeight.
    controller.resizePane(tab.id, (tab.layout.root as PaneSplit).id, 0, 1);
    await tester.pump();

    expect(tester.getSize(find.byType(EmptyPaneRegion)).width, lessThan(80));
    expect(
      tester.state<ScrollableState>(sideways).position.maxScrollExtent,
      greaterThan(0),
      reason: 'the buttons stay reachable rather than painting outside',
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
/// The strip draws tabs in layout order, so the index is the tab's position
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
