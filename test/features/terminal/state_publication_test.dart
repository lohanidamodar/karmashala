import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// What one change to one pane is allowed to tell the rest of the layout.
///
/// The controller used to hand every consumer a fresh copy of everything on
/// every publish, so a process exiting in a background pane rebuilt the tab
/// strip, the pane stack and the toolbar. These pin the narrowing: each
/// projection keeps its identity until the thing it projects actually changes,
/// and the id indexes stay correct across every structural operation.
void main() {
  late TerminalSessionsController controller;
  late ProviderContainer container;

  setUp(() {
    container = fakeTerminalContainer();
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  tearDown(() => container.dispose());

  TerminalSessionsState get$() =>
      container.read(terminalSessionsControllerProvider);

  String onlyPaneOf(String tabId) =>
      get$().tabs.firstWhere((t) => t.id == tabId).layout.panes.single;

  test(
    'a pane exiting tells the topology nothing and that pane everything',
    () async {
      final first = controller.openTab(TerminalProfile.powerShell);
      controller.openTab(TerminalProfile.commandPrompt);
      final pane = onlyPaneOf(first);

      // Listened through `select` on the notifier itself, which is exactly the
      // mechanism the narrow providers are built out of — and the only one that
      // reports synchronously, since a derived `Provider` is recomputed on the
      // container's own schedule.
      var topologyRebuilds = 0;
      var paneRebuilds = 0;
      final onTopology = container.listen(
        terminalSessionsControllerProvider.select((s) => s.tabs),
        (_, _) => topologyRebuilds++,
      );
      final onPane = container.listen(
        terminalSessionsControllerProvider.select((s) => s.livenessOf(pane)),
        (_, _) => paneRebuilds++,
      );
      addTearDown(onTopology.close);
      addTearDown(onPane.close);

      (controller.instanceFor(pane)! as FakeTerminalInstance)
              .livenessNotifier
              .value =
          PaneLiveness.exited;

      expect(topologyRebuilds, 0);
      expect(paneRebuilds, 1);

      await container.pump();
      expect(
        container.read(terminalPaneLivenessProvider(pane)),
        PaneLiveness.exited,
      );
      expect(container.read(terminalTabsProvider).length, 2);
    },
  );

  test('opening a tab keeps the detached list the same object', () {
    controller.openTab(TerminalProfile.powerShell);
    final before = get$().detached;

    controller.openTab(TerminalProfile.commandPrompt);

    expect(identical(get$().detached, before), isTrue);
  });

  test('switching tabs keeps the tab list the same object', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    final before = get$().tabs;

    controller.activateTab(first);

    expect(identical(get$().tabs, before), isTrue);
    expect(get$().activeTabId, first);
  });

  test('the pane index survives splitting and closing', () {
    final tab = controller.openTab(TerminalProfile.powerShell);
    final split = controller.splitPaneWith(
      SplitAxis.horizontal,
      TerminalProfile.powerShell,
    )!;
    final third = controller.splitPaneWith(
      SplitAxis.vertical,
      TerminalProfile.powerShell,
    )!;

    // Focus resolves through the pane -> tab index; a stale one would either
    // miss the pane or point at the wrong tab.
    controller.focusPane(split);
    expect(get$().activeTab!.id, tab);
    expect(get$().activeTab!.focusedPaneId, split);

    controller.closePane(third, detach: false);
    controller.focusPane(split);
    expect(get$().activeTab!.focusedPaneId, split);
    expect(controller.instanceFor(third), isNull);
  });

  test('the tab index survives closing a tab in the middle', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    final second = controller.openTab(TerminalProfile.powerShell);
    final third = controller.openTab(TerminalProfile.powerShell);

    controller.closeTab(second, detach: false);

    expect(controller.titleForTab(first), isNot('Terminal'));
    expect(controller.titleForTab(third), isNot('Terminal'));
    expect(
      controller.titleForTab(second),
      'Terminal',
      reason: 'a tab that is gone must not resolve to whatever took its slot',
    );
    controller.activateTab(third);
    expect(get$().activeTab!.id, third);
  });

  test('detaching and reattaching republishes the detached list', () {
    final first = controller.openTab(TerminalProfile.powerShell);
    controller.openTab(TerminalProfile.commandPrompt);
    final pane = onlyPaneOf(first);
    giveShellHistory(controller.instanceFor(pane)!);

    controller.closeTab(first);
    expect(get$().detached.single.paneId, pane);

    controller.reattachSession(pane);
    expect(get$().detached, isEmpty);
    expect(controller.instanceFor(pane), isNotNull);
  });

  test('a layout answers "contains" without rebuilding its pane list', () {
    final layout = PaneLayout.single(
      'a',
    ).split('a', SplitAxis.horizontal, 'b', 's1');

    // Same object twice: the walk happens once, so a lookup is a set probe
    // rather than an allocation.
    expect(identical(layout.panes, layout.panes), isTrue);
    expect(layout.contains('b'), isTrue);
    expect(layout.contains('nope'), isFalse);
  });
}
