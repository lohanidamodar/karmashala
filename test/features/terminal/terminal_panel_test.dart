import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_search_controller.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/mounted_tabs.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:chitragupta/src/features/terminal/presentation/pane_layout_view.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:chitragupta/src/features/terminal/presentation/terminal_search_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// The workbench reads settings, environments and the selected repository, all
/// of which sit behind the database — so a workbench test needs a real (empty)
/// one. Loop 47 moved the terminal's tab strip into the shell's workbench, so
/// these tests pump the workbench rather than a standalone panel: the tabs and
/// the panes are no longer the same widget.
ProviderContainer panelContainer() {
  final database = AppDatabase.memory();
  addTearDown(database.close);
  final container = fakeTerminalContainer(database: database);
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpPanel(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('opens one terminal when shown with no tabs', (tester) async {
    final container = panelContainer();

    await pumpPanel(tester, container);

    expect(container.read(terminalSessionsControllerProvider).tabs.length, 1);
  });

  testWidgets('keeps inactive tabs alive in an IndexedStack', (tester) async {
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);

    await pumpPanel(tester, container);

    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.children.length, 2, reason: 'both tabs stay alive');
    expect(stack.index, 1, reason: 'only the active one paints');
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      second,
    );
  });

  testWidgets('mounts no more than the tab budget however many are open', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    for (var i = 0; i < kMountedTabBudget + 12; i++) {
      controller.openTab(TerminalProfile.powerShell);
    }

    await pumpPanel(tester, container);

    // `skipOffstage: false`, because `IndexedStack` hides its unselected
    // children from the default finder — which would make this pass by
    // counting one pane whether or not the rest were mounted.
    expect(
      tester
          .widgetList(find.byType(TerminalPaneView, skipOffstage: false))
          .length,
      kMountedTabBudget,
    );
    expect(
      container.read(terminalSessionsControllerProvider).tabs.length,
      kMountedTabBudget + 12,
      reason: 'the tabs all still exist — only their views are bounded',
    );
  });

  testWidgets('switching to an unmounted tab shows its own buffer', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final first = controller.openTab(TerminalProfile.powerShell);
    final firstPane = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .first
        .layout
        .panes
        .single;
    controller.instanceFor(firstPane)!.terminal.write('marker-from-tab-one');
    for (var i = 0; i < kMountedTabBudget + 4; i++) {
      controller.openTab(TerminalProfile.powerShell);
    }

    await pumpPanel(tester, container);
    // Evicted: the budget is full of tabs opened after it.
    expect(find.text('marker-from-tab-one', skipOffstage: false), findsNothing);

    controller.activateTab(first);
    await tester.pump();

    // The same instance came back — the process and its scrollback never went
    // anywhere, only the widgets did.
    expect(controller.instanceFor(firstPane), isNotNull);
    expect(
      controller.instanceFor(firstPane)!.terminal.buffer.getText(),
      contains('marker-from-tab-one'),
    );
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      first,
    );
  });

  testWidgets('shows one tab per open tab and can close one', (tester) async {
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);

    await pumpPanel(tester, container);

    expect(find.text('PowerShell'), findsOneWidget);
    expect(find.text('Command Prompt'), findsOneWidget);

    await tester.tap(
      find.byTooltip('Close tab (the session keeps running)').last,
    );
    await tester.pump();

    expect(container.read(terminalSessionsControllerProvider).tabs.length, 1);
  });

  testWidgets('a split renders both panes in the active tab', (tester) async {
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    controller.splitPaneWith(SplitAxis.horizontal, TerminalProfile.commandPrompt);

    await pumpPanel(tester, container);

    expect(find.byType(PaneDivider), findsOneWidget);
    expect(
      container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .length,
      2,
    );
  });

  testWidgets('the split button splits the focused pane', (tester) async {
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);

    await pumpPanel(tester, container);
    await tester.tap(find.byTooltip('Split right (Ctrl+Shift+D)'));
    await tester.pump();

    expect(
      container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .length,
      2,
    );
  });

  testWidgets('the find button opens the search bar for the focused pane', (
    tester,
  ) async {
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);

    await pumpPanel(tester, container);
    expect(find.byType(TerminalSearchBar), findsNothing);

    await tester.tap(find.byTooltip('Find in scrollback (Ctrl+Shift+F)'));
    await tester.pump();

    expect(find.byType(TerminalSearchBar), findsOneWidget);
    final search = container.read(terminalSearchControllerProvider);
    expect(search.visible, isTrue);
    expect(
      search.paneId,
      container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .focusedPaneId,
    );
  });

  testWidgets('an empty panel says so rather than rendering nothing', (
    tester,
  ) async {
    final container = panelContainer();

    // Pump a single frame so the post-frame "open one terminal" has not run.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );

    expect(find.text('Opening terminal…'), findsOneWidget);
  });
}
