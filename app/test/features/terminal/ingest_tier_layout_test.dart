import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Where a pane sits in the layout is the only thing that decides how much
/// of the UI isolate its output may spend.
///
/// A pane cannot work this out for itself — it cannot see which tab is in
/// front — so the controller tells it, from one place, on every publish. There
/// is deliberately no second path that could leave a pane at the wrong tier.
void main() {
  late TerminalSessionsController controller;
  late ProviderContainer container;

  setUp(() {
    container = fakeTerminalContainer();
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  tearDown(() => container.dispose());

  FakeTerminalInstance pane(String paneId) =>
      controller.instanceFor(paneId)! as FakeTerminalInstance;

  String onlyPaneOf(String tabId) => container
      .read(terminalSessionsControllerProvider)
      .tabs
      .firstWhere((t) => t.id == tabId)
      .layout
      .panes
      .single;

  test('the active tab is hot and every other open tab is warm', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);

    expect(pane(onlyPaneOf(second)).ingestTier, IngestTier.hot);
    expect(
      pane(onlyPaneOf(first)).ingestTier,
      IngestTier.warm,
      reason: 'open, correct, but nobody is watching it draw',
    );
  });

  test('switching tabs swaps which pane owns the frame', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.commandPrompt);

    controller.activateTab(first);

    expect(pane(onlyPaneOf(first)).ingestTier, IngestTier.hot);
    expect(pane(onlyPaneOf(second)).ingestTier, IngestTier.warm);
  });

  test('both panes of a split active tab are hot — both are on screen', () {
    controller.openTab(TerminalProfile.powerShell);
    final split = controller.splitPaneWith(
      SplitAxis.horizontal,
      TerminalProfile.powerShell,
    )!;
    final tab = container.read(terminalSessionsControllerProvider).activeTab!;

    expect(tab.layout.panes.length, 2);
    expect(pane(split).ingestTier, IngestTier.hot);
    for (final paneId in tab.layout.panes) {
      expect(pane(paneId).ingestTier, IngestTier.hot);
    }
  });

  // Cold was the tier of a pane kept with no tab. Since 2026-09-30 a closed
  // tab drops its pane — the server keeps the terminal — so nothing in this
  // window is ever cold; these pin that nothing lingers to be.
  test('a closed tab\'s pane is dropped, not kept cold', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    final closedPane = onlyPaneOf(first);
    final instance = pane(closedPane);
    giveShellHistory(instance);

    controller.closeTab(first);

    expect(container.read(terminalSessionsControllerProvider).detached, []);
    expect(controller.instanceFor(closedPane), isNull);
    expect(instance.disposed, isTrue);
    expect(instance.ingestTier, isNot(IngestTier.cold));
  });

  test('reopening is a tab again, hot in one step', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    final closed = pane(onlyPaneOf(first));
    giveShellHistory(closed);
    controller.closeTab(first);

    final reopened = controller.openTab(TerminalProfile.powerShell);

    expect(pane(onlyPaneOf(reopened)).ingestTier, IngestTier.hot);
    // Warm when the second tab took the front, and no step after it: the tier
    // is derived from the layout, and a dropped pane is in none.
    expect(closed.tierHistory, [IngestTier.warm]);
  });

  test('one pane is hot however many tabs are open', () {
    for (var i = 0; i < 20; i++) {
      controller.openTab(TerminalProfile.powerShell);
    }
    final state = container.read(terminalSessionsControllerProvider);

    final hot = [
      for (final tab in state.tabs)
        for (final paneId in tab.layout.panes)
          if (pane(paneId).ingestTier == IngestTier.hot) paneId,
    ];

    expect(hot.length, 1);
    expect(hot.single, onlyPaneOf(state.activeTabId!));
  });
}
