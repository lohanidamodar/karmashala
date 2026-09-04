import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// Splitting a pane used to launch a shell into the new half. The report:
/// *"when splitting the middle workspace, don't automatically start a terminal,
/// it should be able to create new tab or move existing tabs around in the
/// split ... just create empty split where i can drag and move existing tabs or
/// create new tabs"*.
///
/// So a split now divides *space* and nothing else: the new region is a leaf in
/// the layout with no instance behind it, and the user fills it — with a new
/// terminal, or with a tab moved in. Nothing about the pane that was split
/// changes: it is not duplicated, forked or re-run.
void main() {
  /// A container whose factory counts panes, so "splitting starts nothing" is
  /// asserted rather than inferred from the layout.
  ({ProviderContainer container, List<String> created}) countingContainer() {
    final created = <String>[];
    final container = ProviderContainer(
      overrides: fakeTerminalOverrides(
        instanceFactory:
            ({
              required String id,
              required TerminalProfile profile,
              String? workingDirectory,
              String? restoredScrollback,
              bool shellIntegration = false,
              AgentPaneLaunch? agentLaunch,
              Terminal? adoptTerminal,
            }) {
              created.add(id);
              return defaultFakeInstanceFactory(
                id: id,
                profile: profile,
                workingDirectory: workingDirectory,
                restoredScrollback: restoredScrollback,
                shellIntegration: shellIntegration,
                agentLaunch: agentLaunch,
                adoptTerminal: adoptTerminal,
              );
            },
      ),
    );
    addTearDown(container.dispose);
    return (container: container, created: created);
  }

  TerminalSessionsController controllerOf(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider.notifier);

  TerminalTab activeTab(ProviderContainer container) =>
      container.read(terminalSessionsControllerProvider).activeTab!;

  group('splitting leaves the new region empty', () {
    test('starts no process and creates no second session', () {
      final (:container, :created) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      expect(created, hasLength(1), reason: 'the tab itself');

      final slot = controller.splitPane(SplitAxis.horizontal)!;

      expect(
        created,
        hasLength(1),
        reason: 'a split is room to put something in, not something to run',
      );
      expect(controller.instanceFor(slot), isNull);
      expect(activeTab(container).layout.panes, hasLength(2));
    });

    test('leaves the session it split running, untouched, in its own pane', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final first = activeTab(container).layout.panes.single;
      final before = controller.instanceFor(first)!;
      before.terminal.write('work in progress');

      controller.splitPane(SplitAxis.vertical);

      expect(
        controller.instanceFor(first),
        same(before),
        reason: 'the active session is not split into two, forked or re-run',
      );
      expect(before.liveness.value, PaneLiveness.live);
      expect((before as FakeTerminalInstance).disposed, isFalse);
      expect(
        before.terminal.buffer.lines[0].toString(),
        contains('work in progress'),
      );
    });

    test('focuses the new region, so what fills it lands there', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);

      final slot = controller.splitPane(SplitAxis.horizontal)!;

      expect(activeTab(container).focusedPaneId, slot);
      expect(controller.isEmptySlot(slot), isTrue);
    });

    test('refuses to divide a region that is already empty', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      controller.splitPane(SplitAxis.horizontal);

      expect(
        controller.splitPane(SplitAxis.horizontal),
        isNull,
        reason: 'an empty region divided in two is two empty regions',
      );
      expect(activeTab(container).layout.panes, hasLength(2));
    });
  });

  group('filling an empty region', () {
    test('a new terminal can be opened straight into it', () {
      final (:container, :created) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final first = activeTab(container).layout.panes.single;
      final slot = controller.splitPane(SplitAxis.horizontal)!;

      final opened = controller.openInSlot(
        slot,
        TerminalProfile.commandPrompt,
      )!;

      expect(created, hasLength(2));
      expect(controller.instanceFor(opened), isNotNull);
      expect(activeTab(container).layout.panes, [first, opened]);
      expect(activeTab(container).focusedPaneId, opened);
      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1), reason: 'it filled a region, not a tab');
    });

    test('a new agent session can be opened straight into it', () {
      final (:container, :created) = countingContainer();
      final controller = controllerOf(container);
      final host = controller.openTab(TerminalProfile.powerShell);
      final first = activeTab(container).layout.panes.single;
      final slot = controller.splitPane(SplitAxis.horizontal)!;

      final opened = controller.openAgentInSlot(
        slot,
        const AgentPaneLaunch(
          agentId: 'codex',
          executable: 'codex',
          sessionId: 'session-1',
        ),
      )!;

      expect(created, hasLength(2), reason: 'one shell and one agent');
      expect(opened.tabId, host, reason: 'the split is filled in place');
      expect(activeTab(container).layout.panes, [first, opened.paneId]);
      expect(activeTab(container).focusedPaneId, opened.paneId);
      expect(controller.instanceFor(opened.paneId)!.agentLaunch?.agentId, 'codex');
    });

    test('a stale session target starts nothing', () {
      final (:container, :created) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);

      expect(
        controller.openAgentInSlot(
          'missing',
          const AgentPaneLaunch(agentId: 'codex', executable: 'codex'),
        ),
        isNull,
      );
      expect(created, hasLength(1), reason: 'validation happens before spawn');
    });

    test('a tab moved in brings the very same session, not a new one', () {
      final (:container, :created) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final host = activeTab(container).id;
      final kept = activeTab(container).layout.panes.single;
      final movedTab = controller.openTab(TerminalProfile.commandPrompt);
      final movedPane = activeTab(container).layout.panes.single;
      final instance = controller.instanceFor(movedPane)!;
      controller.activateTab(host);
      final slot = controller.splitPane(SplitAxis.horizontal)!;

      expect(controller.moveTabIntoSlot(movedTab, slot), isTrue);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1), reason: 'the tab left the strip');
      expect(state.activeTab!.id, host);
      expect(state.activeTab!.layout.panes, [kept, movedPane]);
      expect(created, hasLength(2), reason: 'moving is not launching');
      expect(controller.instanceFor(movedPane), same(instance));
      expect(instance.liveness.value, PaneLiveness.live);
      expect((instance as FakeTerminalInstance).disposed, isFalse);
    });

    test('a tab that is itself split moves in whole', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final host = activeTab(container).id;
      final kept = activeTab(container).layout.panes.single;

      final movedTab = controller.openTab(TerminalProfile.commandPrompt);
      final left = activeTab(container).layout.panes.single;
      final rightSlot = controller.splitPane(SplitAxis.vertical)!;
      final right = controller.openInSlot(
        rightSlot,
        TerminalProfile.powerShell,
      )!;

      controller.activateTab(host);
      final slot = controller.splitPane(SplitAxis.horizontal)!;
      expect(controller.moveTabIntoSlot(movedTab, slot), isTrue);

      final tab = activeTab(container);
      expect(tab.layout.panes, [kept, left, right]);
      expect(
        (tab.layout.root as PaneSplit).children[1],
        isA<PaneSplit>(),
        reason: 'the moved tab keeps its own rows inside the new column',
      );
    });

    test('and back out again into a tab of its own, collapsing the split', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final host = activeTab(container).id;
      final kept = activeTab(container).layout.panes.single;
      final movedTab = controller.openTab(TerminalProfile.commandPrompt);
      final movedPane = activeTab(container).layout.panes.single;
      final instance = controller.instanceFor(movedPane)!;
      controller.activateTab(host);
      final slot = controller.splitPane(SplitAxis.horizontal)!;
      controller.moveTabIntoSlot(movedTab, slot);

      final newTab = controller.movePaneToNewTab(movedPane)!;

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(2));
      expect(state.activeTabId, newTab);
      expect(state.activeTab!.layout.panes, [movedPane]);
      expect(
        state.tabs.firstWhere((t) => t.id == host).layout.panes,
        [kept],
        reason: 'the region it left goes with it — the split collapses',
      );
      expect(controller.instanceFor(movedPane), same(instance));
      expect(instance.liveness.value, PaneLiveness.live);
    });

    test('a tab left holding nothing but empty regions goes', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final only = activeTab(container).layout.panes.single;
      controller.splitPane(SplitAxis.horizontal);

      controller.movePaneToNewTab(only);

      final state = container.read(terminalSessionsControllerProvider);
      expect(
        state.tabs,
        hasLength(1),
        reason: 'a tab with nothing in it and nothing to come back to is not '
            'a tab',
      );
      expect(state.activeTab!.layout.panes, [only]);
    });

    test('closing an empty region collapses the split and ends nothing', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      controller.openTab(TerminalProfile.powerShell);
      final only = activeTab(container).layout.panes.single;
      final instance = controller.instanceFor(only)! as FakeTerminalInstance;
      final slot = controller.splitPane(SplitAxis.horizontal)!;

      controller.closePane(slot);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1));
      expect(state.activeTab!.layout.panes, [only]);
      expect(state.activeTab!.focusedPaneId, only);
      expect(instance.disposed, isFalse);
      expect(state.detached, isEmpty, reason: 'an empty region is no session');
    });

    test('closing the last real pane takes its empty region with it', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      final survivor = controller.openTab(TerminalProfile.powerShell);
      controller.openTab(TerminalProfile.commandPrompt);
      final only = activeTab(container).layout.panes.single;
      controller.splitPane(SplitAxis.horizontal);

      controller.closePane(only, detach: false);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, hasLength(1));
      expect(state.tabs.single.id, survivor);
    });
  });

  group('a tab keeps its name while a region of it is empty', () {
    test('an empty region has no name of its own', () {
      final (:container, created: _) = countingContainer();
      final controller = controllerOf(container);
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final named = controller.titleForTab(tabId);

      controller.splitPane(SplitAxis.horizontal);

      expect(controller.titleForTab(tabId), startsWith(named));
    });
  });
}
