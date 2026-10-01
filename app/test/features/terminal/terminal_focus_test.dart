import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/tokens.dart';

import 'fake_instance.dart';
import '../../support/test_machine.dart';

/// Making a terminal pane the active one must make it *typable*.
///
/// The controller has always tracked a focused pane id, but tracking it is only
/// half the job: unless the pane's `FocusNode` is actually asked for focus, the
/// user has to click inside the terminal before the keyboard reaches it — which
/// is what the owner reported after switching tabs. These tests cover every way
/// a pane becomes the active one.
void main() {
  /// This machine's client, at [density]. `flutter_test` reports Android as
  /// the platform, so the measured density is touch, where the controller
  /// leaves focus to a tap on the grid; the cases here are a pointer's.
  ClientCapabilities clientAt(UiDensity density) {
    final measured = ClientCapabilities.measure();
    return ClientCapabilities(
      systemIntegration: measured.systemIntegration,
      osToasts: measured.osToasts,
      localNotifications: measured.localNotifications,
      localDevices: measured.localDevices,
      externalApps: measured.externalApps,
      fileDrop: measured.fileDrop,
      relaunch: measured.relaunch,
      density: density,
      hostsServer: measured.hostsServer,
      multicastLock: measured.multicastLock,
      mediaPlayback: measured.mediaPlayback,
      deviceName: measured.deviceName,
      camera: measured.camera,
    );
  }

  ProviderContainer panelContainer({UiDensity density = UiDensity.pointer}) {
    final database = TestMachine();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: database),
        clientCapabilitiesProvider.overrideWithValue(clientAt(density)),
      ],
    );
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

    final pane = controller.splitPaneWith(
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
    final right = controller.splitPaneWith(
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

  testWidgets('an evicted tab is typable the moment it comes back', (
    tester,
  ) async {
    // The mounted set is bounded, so most tabs in a hundred-tab layout have
    // no widgets at all. Focus lives on the pane's own `FocusNode`, which the
    // controller owns and the view only borrows — so coming back must land the
    // keyboard in the pane without a click, exactly as a mounted tab does.
    final container = panelContainer();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final firstPane = soleePaneOf(container, first);
    for (var i = 0; i < kMountedTabBudget + 4; i++) {
      controller.openTab(TerminalProfile.powerShell);
    }
    await pumpPanel(tester, container);

    // `skipOffstage: false`, because `IndexedStack` hides its unselected
    // children from the default finder.
    int mountedViews() => tester
        .widgetList(find.byType(TerminalPaneView, skipOffstage: false))
        .length;
    expect(mountedViews(), kMountedTabBudget);
    expect(paneHasFocus(container, firstPane), isFalse);

    controller.activateTab(first);
    await tester.pump();

    expect(paneHasFocus(container, firstPane), isTrue);
    expect(mountedViews(), kMountedTabBudget, reason: 'and still bounded');
  });

  testWidgets('an unmounted tab is a warm pane, not a detached one', (
    tester,
  ) async {
    // Bounding the *views* must not change what the pane is. A tab with no
    // widgets is still open, so its process runs, its output is parsed, and it
    // holds its buffer — cold is for a session with no tab at all, and nothing
    // about it may be decided by whether a widget happens to exist.
    final container = panelContainer();
    final controller = controllerOf(container);
    final first = controller.openTab(TerminalProfile.powerShell);
    final firstPane = soleePaneOf(container, first);
    for (var i = 0; i < kMountedTabBudget + 4; i++) {
      controller.openTab(TerminalProfile.powerShell);
    }
    await pumpPanel(tester, container);

    final instance = controller.instanceFor(firstPane)! as FakeTerminalInstance;
    expect(instance.ingestTier, IngestTier.warm);

    instance.receive('while-unmounted\r\n');
    controller.activateTab(first);
    await tester.pump();

    expect(instance.ingestTier, IngestTier.hot);
    expect(
      instance.terminal.buffer.getText(),
      contains('while-unmounted'),
      reason: 'output that arrived with no view on screen is not output lost',
    );
  });
}
