import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/pty_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import 'fake_instance.dart';

void main() {
  group('terminalProfilesFor', () {
    test('always offers PowerShell and Command Prompt, then WSL distros', () {
      final profiles = terminalProfilesFor([
        windowsEnv(),
        wslEnv(distro: 'Ubuntu'),
        wslEnv(id: 'wsl:Debian', distro: 'Debian'),
      ]);
      expect(profiles.map((p) => p.id), [
        'powershell',
        'cmd',
        'wsl:Ubuntu',
        'wsl:Debian',
      ]);
      expect(profiles[2].shell, TerminalShell.wsl);
      expect(profiles[2].wslDistribution, 'Ubuntu');
    });

    test(
      'resolveTerminalProfile falls back to the first when id is unknown',
      () {
        final profiles = terminalProfilesFor([windowsEnv()]);
        expect(resolveTerminalProfile('wsl:Gone', profiles).id, 'powershell');
        expect(resolveTerminalProfile('cmd', profiles).id, 'cmd');
      },
    );
  });

  group('ptyLaunchFor', () {
    test('PowerShell runs powershell.exe with the host working dir', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws\app',
      );
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments, ['-NoLogo']);
      expect(launch.workingDirectory, r'C:\ws\app');
    });

    test('WSL launches the distro via wsl.exe --cd, not a host cwd', () {
      final launch = ptyLaunchFor(
        const TerminalProfile(
          id: 'wsl:Ubuntu',
          label: 'Ubuntu (WSL)',
          shell: TerminalShell.wsl,
          wslDistribution: 'Ubuntu',
        ),
        workingDirectory: '/home/me/app',
      );
      expect(launch.executable, 'wsl.exe');
      expect(launch.arguments, ['-d', 'Ubuntu', '--cd', '/home/me/app']);
      expect(launch.workingDirectory, isNull);
    });
  });

  group('TerminalSessionsController', () {
    test('opens tabs, activates the newest, and switches', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );

      final first = controller.openTab(TerminalProfile.powerShell);
      final second = controller.openTab(TerminalProfile.commandPrompt);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs.length, 2);
      expect(state.activeTabId, second);

      controller.activateTab(first);
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        first,
      );
    });

    test('closing the active tab detaches its panes and activates another', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final first = controller.openTab(TerminalProfile.powerShell);
      final second = controller.openTab(TerminalProfile.commandPrompt);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((t) => t.id == second)
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;

      controller.closeTab(second);

      final state = container.read(terminalSessionsControllerProvider);
      // The view is gone; the process is not.
      expect(state.tabs.length, 1);
      expect(state.activeTabId, first);
      expect(instance.disposed, isFalse);
      expect(controller.instanceFor(pane), same(instance));
      expect(state.detached.map((s) => s.paneId), [pane]);
      expect(state.livenessOf(pane), PaneLiveness.live);
    });

    test('splitting adds a pane to the active tab and focuses it', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final newPane = controller.splitPane(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;

      final tab = container.read(terminalSessionsControllerProvider).activeTab!;
      expect(tab.layout.panes.length, 2);
      expect(tab.focusedPaneId, newPane);
      expect(controller.instanceFor(newPane), isNotNull);
    });

    test('splitting with no tab open does nothing', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(
        controller.splitPane(SplitAxis.horizontal, TerminalProfile.powerShell),
        isNull,
      );
    });

    test('closing a pane collapses the split and keeps the tab', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final second = controller.splitPane(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      )!;
      final instance = controller.instanceFor(second)! as FakeTerminalInstance;

      controller.closePane(second);

      final state = container.read(terminalSessionsControllerProvider);
      final tab = state.activeTab!;
      expect(instance.disposed, isFalse, reason: 'closing a pane detaches it');
      expect(state.detached.map((s) => s.paneId), [second]);
      expect(tab.layout.panes.length, 1);
      expect(tab.focusedPaneId, tab.layout.panes.single);
    });

    test('closing the last pane of a tab closes the tab', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final only = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;

      controller.closePane(only);

      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    });

    test('movePaneFocus walks the tree and stops at the edge', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final left = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final right = controller.splitPane(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;

      controller.movePaneFocus(PaneDirection.left);
      expect(
        container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .focusedPaneId,
        left,
      );
      controller.movePaneFocus(PaneDirection.left);
      expect(
        container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .focusedPaneId,
        left,
        reason: 'already at the edge',
      );
      controller.movePaneFocus(PaneDirection.right);
      expect(
        container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .focusedPaneId,
        right,
      );
    });

    test('nextTab and previousTab wrap', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final first = controller.openTab(TerminalProfile.powerShell);
      final second = controller.openTab(TerminalProfile.commandPrompt);

      controller.nextTab();
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        first,
      );
      controller.previousTab();
      expect(
        container.read(terminalSessionsControllerProvider).activeTabId,
        second,
      );
    });

    test('a tab title names the focused pane and counts the panes', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      expect(controller.titleForTab(tabId), 'PowerShell');

      controller.splitPane(SplitAxis.horizontal, TerminalProfile.commandPrompt);
      expect(controller.titleForTab(tabId), 'Command Prompt (2)');
    });
  });

  group('terminalVisibleProvider', () {
    test('toggles visibility', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(terminalVisibleProvider), isFalse);
      container.read(terminalVisibleProvider.notifier).toggle();
      expect(container.read(terminalVisibleProvider), isTrue);
    });
  });
}
