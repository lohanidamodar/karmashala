import 'package:karmashala/src/app/shell/app_shell.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/features/terminal/application/terminal_search_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_layout_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_search_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import '../../support/test_machine.dart';

/// The workbench reads settings, environments and the selected repository, all
/// of which sit behind the database — so a workbench test needs a real (empty)
/// one. Loop 47 moved the terminal's tab strip into the shell's workbench, so
/// these tests pump the workbench rather than a standalone panel: the tabs and
/// the panes are no longer the same widget.
ProviderContainer panelContainer() {
  final database = TestMachine();
  final container = fakeTerminalContainer(machine: database);
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

/// The workbench **with the window chrome over it**, for the controls that
/// belong to the window rather than to a workspace group: the restored-session
/// badge, usage and Zen.
Future<void> pumpWindowChrome(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(appBar: ShellTitleBar(), body: WorkbenchView()),
      ),
    ),
  );
  await tester.pump();
}

/// The workbench **under the group toolbar** ([TerminalToolbar]): split,
/// find and new terminal for the focused group. The title bar carried these
/// until it was cut to usage, one New and Zen (5c1fe3f58); the toolbar is
/// where the buttons — and the room check that disables one — still live.
Future<void> pumpWithToolbar(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TerminalToolbar(),
              ),
              Expanded(child: WorkbenchView()),
            ],
          ),
        ),
      ),
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

    // On the strip: the shown pane's status line names its profile too.
    Finder chip(String title) => find.descendant(
      of: find.byType(WorkbenchTabChip),
      matching: find.text(title),
    );
    expect(chip('PowerShell'), findsOneWidget);
    expect(chip('Command Prompt'), findsOneWidget);

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
    controller.splitPaneWith(
      SplitAxis.horizontal,
      TerminalProfile.commandPrompt,
    );

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

  testWidgets('the split button divides the workspace, not the pane', (
    tester,
  ) async {
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);

    await pumpWithToolbar(tester, container);
    await tester.tap(
      find.byTooltip('Split the workspace right (Ctrl+Shift+D)'),
    );
    await tester.pump();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.workspace!.groups, hasLength(2));
    // The tab that was split is untouched: it is the *workspace* that divided,
    // and the new group is empty room.
    expect(state.tabs.single.layout.panes, hasLength(1));
  });

  testWidgets('the split buttons divide an empty group too', (tester) async {
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pumpWithToolbar(tester, container);

    await tester.tap(
      find.byTooltip('Split the workspace right (Ctrl+Shift+D)'),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Split the workspace down (Ctrl+Shift+E)'));
    await tester.pump();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.workspace!.groups, hasLength(3));
    expect(state.tabs, hasLength(1));
    expect(find.text('Empty group'), findsNWidgets(2));
  });

  testWidgets('a group too narrow to halve says so on the button it disables', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    for (var i = 0; i < 4; i++) {
      controller.splitWorkspace(SplitAxis.horizontal);
    }
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpWithToolbar(tester, container);

    final refused = find.byTooltip('This group is too narrow to split again');
    expect(refused, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: refused, matching: find.byType(IconButton)),
          )
          .onPressed,
      isNull,
    );
    // Only the axis that ran out.
    await tester.tap(find.byTooltip('Split the workspace down (Ctrl+Shift+E)'));
    await tester.pump();
    expect(
      container.read(terminalSessionsControllerProvider).workspace!.groups,
      hasLength(6),
    );

    // Somewhere with room, the same button is back.
    controller.focusGroup(
      container
          .read(terminalSessionsControllerProvider)
          .workspace!
          .groups
          .first
          .id,
    );
    await tester.pump();
    expect(refused, findsNothing);
    expect(
      find.byTooltip('Split the workspace right (Ctrl+Shift+D)'),
      findsOneWidget,
    );
  });

  testWidgets('the find button opens the search bar for the focused pane', (
    tester,
  ) async {
    final container = panelContainer();
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);

    await pumpWithToolbar(tester, container);
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

  testWidgets('but once the user closes the last tab it offers a way back', (
    tester,
  ) async {
    // The reported bug: the panel sat on "Opening terminal…" for ever. That
    // message is a promise the panel only keeps once — the automatic open runs
    // when it mounts and never again — so after a close it described something
    // that was not happening, beside no control that would make it happen.
    final container = panelContainer();
    await pumpPanel(tester, container);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final opened = container.read(terminalSessionsControllerProvider).tabs;
    expect(opened, hasLength(1), reason: 'the automatic open has run');

    controller.closeTab(opened.single.id);
    await tester.pump();

    expect(find.text('Opening terminal…'), findsNothing);
    expect(find.text('No terminal open'), findsOneWidget);

    final button = find.ancestor(
      of: find.textContaining('New terminal'),
      matching: find.byType(FilledButton),
    );
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();

    expect(
      container.read(terminalSessionsControllerProvider).tabs,
      hasLength(1),
      reason: 'the button is the way back, not decoration',
    );
    expect(find.text('No terminal open'), findsNothing);
  });

  /// The report was "resizing doesn't work as expected", with a wide, short
  /// pane. The divider fell behind the pointer by the ratio of the window's
  /// long side to the split's own extent, so it was worst exactly here: at
  /// 1440x560 a top/bottom divider moved 36 px for every 100 the mouse did,
  /// and at 720x900 a left/right one moved 164 for every 200.
  ///
  /// End-to-end on purpose. `pane_layout_view_test.dart` pins the share the
  /// divider reports; this pins the only thing the user can see, which is where
  /// the line ends up.
  group('a divider follows the pointer', () {
    Future<double> dragBy(
      WidgetTester tester,
      Size window,
      SplitAxis axis,
      Offset by,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = window;
      addTearDown(tester.view.reset);
      final container = panelContainer();
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      controller.splitPaneWith(axis, TerminalProfile.commandPrompt);

      await pumpPanel(tester, container);

      final before = tester.getCenter(find.byType(PaneDivider));
      await tester.drag(find.byType(PaneDivider), by);
      await tester.pump();
      final after = tester.getCenter(find.byType(PaneDivider));
      return axis == SplitAxis.horizontal
          ? after.dx - before.dx
          : after.dy - before.dy;
    }

    testWidgets('down, in a wide short window', (tester) async {
      expect(
        await dragBy(
          tester,
          const Size(1440, 560),
          SplitAxis.vertical,
          const Offset(0, 100),
        ),
        closeTo(100, 1),
      );
    });

    testWidgets('across, in a tall narrow window', (tester) async {
      expect(
        await dragBy(
          tester,
          const Size(720, 900),
          SplitAxis.horizontal,
          const Offset(200, 0),
        ),
        closeTo(200, 1),
      );
    });
  });
}
