import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';

import 'fake_instance.dart';

/// **A chat tab is a tab**: a pane bound to a session with no process behind
/// it, so the tab machinery — strip, focus, close, restore — applies and only
/// the surface differs. Terminal-only here: what the tab is *called* with a
/// database behind it is the workbench's test.
void main() {
  group('a chat tab', () {
    test('opens once per session and names that session as its pane', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tabId = controller.openChatTab('acp-1');
      final again = controller.openChatTab('acp-1');

      expect(again, tabId);
      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs.map((tab) => tab.id), [tabId]);
      expect(state.activeTabId, tabId);
      expect(state.tabs.single.layout.panes, [chatPaneId('acp-1')]);

      final panes = container.read(paneSessionsProvider);
      expect(panes.paneOf('acp-1'), chatPaneId('acp-1'));
      expect(panes.sessionOf(chatPaneId('acp-1')), 'acp-1');
      // Nothing runs in it: it is not a live pane to anyone asking for one.
      expect(panes.paneOf('acp-1', where: (l) => l.isLive), isNull);
      expect(controller.instanceFor(chatPaneId('acp-1')), isNull);
      expect(state.livenessOf(chatPaneId('acp-1')), PaneLiveness.exited);
    });

    test('is named for its session, and falls back without a database', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tabId = controller.openChatTab('acp-1');

      expect(controller.titleForTab(tabId), 'Session');
    });

    test('switches with a terminal tab like any two tabs', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final shell = controller.openTab(TerminalProfile.powerShell);
      final chat = controller.openChatTab('acp-1');
      expect(container.read(activePaneSessionIdProvider), 'acp-1');

      controller.activateTab(shell);
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        shell,
      );
      expect(container.read(activePaneSessionIdProvider), isNull);

      controller.activateTab(chat);
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        chat,
      );
      expect(container.read(activePaneSessionIdProvider), 'acp-1');
      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        hasLength(2),
      );
    });

    test('closes as a view: nothing to end, and the session is forgotten '
        'by no one but this window', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final tabId = controller.openChatTab('acp-1');
      controller.closeTab(tabId);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs, isEmpty);
      expect(state.detached, isEmpty);
      expect(container.read(paneSessionsProvider).paneOf('acp-1'), isNull);
    });

    test('comes back from the stored layout pointing at its session', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(layoutStore: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final chat = controller.openChatTab('acp-1');
      controller.persistLayout();
      first.dispose();

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      final restoredController = next.read(
        terminalSessionsControllerProvider.notifier,
      );

      expect(restored.tabs.map((tab) => tab.id), contains(chat));
      expect(restored.activeTabId, chat);
      expect(
        next.read(paneSessionsProvider).paneOf('acp-1'),
        chatPaneId('acp-1'),
      );
      // Rebuilt by being drawn: no instance, no phantom process.
      expect(restoredController.instanceFor(chatPaneId('acp-1')), isNull);
      expect(restoredController.restoredAgentPanes(), isEmpty);
    });
  });
}
