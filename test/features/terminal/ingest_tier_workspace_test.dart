import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/ingest_tier.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Where a pane sits in the workspace is the only thing that decides how much
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

  test('a detached session goes cold — no tab, no parsing', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    final detachedPane = onlyPaneOf(first);
    final instance = pane(detachedPane);
    // A pane worth detaching: an idle plain shell is released on close.
    giveShellHistory(instance);

    controller.closeTab(first);

    expect(
      container.read(terminalSessionsControllerProvider).detached.single.paneId,
      detachedPane,
    );
    expect(instance.ingestTier, IngestTier.cold);
  });

  test('reattaching brings it back hot, in one step', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    final detachedPane = onlyPaneOf(first);
    final instance = pane(detachedPane);
    giveShellHistory(instance);
    controller.closeTab(first);
    expect(instance.ingestTier, IngestTier.cold);

    controller.reattachSession(detachedPane);

    expect(instance.ingestTier, IngestTier.hot);
    // Warm when the second tab took the front, cold when its own tab closed,
    // hot again when it came back — three transitions and no others, because
    // the tier is derived from the workspace rather than stepped through.
    expect(instance.tierHistory, [
      IngestTier.warm,
      IngestTier.cold,
      IngestTier.hot,
    ]);
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
