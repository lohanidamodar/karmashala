import 'package:chitragupta/src/app/shell/workbench.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Making a terminal pane the active one must make it *typable*.
///
/// The controller has always tracked a focused pane id, but tracking it is only
/// half the job: unless the pane's `FocusNode` is actually asked for focus, the
/// user has to click inside the terminal before the keyboard reaches it — which
/// is what the owner reported after switching tabs. These tests cover every way
/// a pane becomes the active one.
void main() {
  ProviderContainer panelContainer() {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final container = fakeTerminalContainer(database: database);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpPanel(
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

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  /// The pane the controller says is focused, and whether Flutter agrees.
  bool paneHasFocus(ProviderContainer container, String paneId) =>
      controllerOf(container).instanceFor(paneId)?.focusNode.hasFocus ?? false;

  String soleePaneOf(ProviderContainer container, String tabId) {
    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    return tabs.firstWhere((t) => t.id == tabId).layout.panes.single;
  }

  testWidgets('activating a tab focuses its pane', (tester) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    await pumpPanel(tester, container);

    controller.activateTab(first);
    await tester.pump();

    expect(paneHasFocus(container, soleePaneOf(container, first)), isTrue);
  });

  testWidgets('stepping tabs focuses the pane stepped to', (tester) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);
    await pumpPanel(tester, container);

    controller.nextTab();
    await tester.pump();
    expect(paneHasFocus(container, soleePaneOf(container, first)), isTrue);

    controller.previousTab();
    await tester.pump();
    expect(paneHasFocus(container, soleePaneOf(container, second)), isTrue);
  });

  testWidgets('opening a tab makes the new pane typable at once', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    final opened = controller.openTab(TerminalProfile.commandPrompt);
    await tester.pump();

    expect(paneHasFocus(container, soleePaneOf(container, opened)), isTrue);
  });

  testWidgets('closing the active tab focuses whichever becomes active', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);
    await pumpPanel(tester, container);

    controller.closeTab(second);
    await tester.pump();

    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      first,
    );
    expect(paneHasFocus(container, soleePaneOf(container, first)), isTrue);
  });

  testWidgets('splitting focuses the new pane', (tester) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    final pane = controller.splitPane(
      SplitAxis.horizontal,
      TerminalProfile.commandPrompt,
    )!;
    await tester.pump();

    expect(paneHasFocus(container, pane), isTrue);
  });

  testWidgets('movePaneFocus moves the keyboard, not just the model', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    final tabId = controller.openTab(TerminalProfile.powerShell);
    final left = soleePaneOf(container, tabId);
    final right = controller.splitPane(
      SplitAxis.horizontal,
      TerminalProfile.commandPrompt,
    )!;
    await pumpPanel(tester, container);

    controller.movePaneFocus(PaneDirection.left);
    await tester.pump();
    expect(paneHasFocus(container, left), isTrue);

    controller.movePaneFocus(PaneDirection.right);
    await tester.pump();
    expect(paneHasFocus(container, right), isTrue);
  });

  testWidgets('a pane does not steal focus from a text field on screen', (
    tester,
  ) async {
    final container = panelContainer();
    final controller = controllerOf(container);
    controller.openTab(TerminalProfile.powerShell);
    await pumpPanel(tester, container);

    // Something modal is up and the user is typing in it — quick open, the
    // composer, a dialog, the search bar. Terminal bookkeeping must not pull
    // the keyboard out from under them.
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: TextField(focusNode: field)),
                const Expanded(child: WorkbenchView()),
              ],
            ),
          ),
        ),
      ),
    );
    field.requestFocus();
    await tester.pump();
    expect(field.hasFocus, isTrue);

    final opened = controller.openTab(TerminalProfile.commandPrompt);
    await tester.pump();

    expect(
      field.hasFocus,
      isTrue,
      reason: 'the text field the user is typing in keeps the keyboard',
    );
    expect(paneHasFocus(container, soleePaneOf(container, opened)), isFalse);
  });
}
