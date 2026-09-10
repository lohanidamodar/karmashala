import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
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
      expect(launch.executable, 'cmd.exe');
      expect(launch.arguments, [
        '/c',
        'wsl.exe -d Ubuntu --cd /home/me/app',
      ]);
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
      // A pane worth detaching: an idle plain shell is released on close.
      giveShellHistory(instance);

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
      final newPane = controller.splitPaneWith(
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
        controller.splitPaneWith(SplitAxis.horizontal, TerminalProfile.powerShell),
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
      final second = controller.splitPaneWith(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      )!;
      final instance = controller.instanceFor(second)! as FakeTerminalInstance;
      giveShellHistory(instance);

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
      final right = controller.splitPaneWith(
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

    test('a tab names its pane, and stops naming one once it splits', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      expect(controller.titleForTab(tabId), 'PowerShell');

      // Before regions had headers this read 'Command Prompt (2)'. Now each
      // region names itself, so a tab that kept borrowing the focused pane's
      // name showed it twice and counted panes already visible. These stubs
      // have no working directory to fall back to, so the borrowed name
      // remains — but the count, which is what made it look like a second tab
      // strip, is gone.
      controller.splitPaneWith(SplitAxis.horizontal, TerminalProfile.commandPrompt);
      expect(controller.titleForTab(tabId), isNot(contains('(')));
    });
  });

  group('a group\'s face', () {
    test('rests on the terminal, and toggles off it', () {
      // The app is terminal-primary, so the terminal is the resting state
      // rather than something every path has to switch to.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final faces = container.read(terminalFacesProvider.notifier);
      expect(container.read(terminalVisibleInGroupProvider('g1')), isTrue);
      faces.toggle('g1');
      expect(container.read(terminalVisibleInGroupProvider('g1')), isFalse);
      faces.toggle('g1');
      expect(container.read(terminalVisibleInGroupProvider('g1')), isTrue);
    });

    test('is one group\'s business and not its neighbour\'s', () {
      // The assertion that carries the weight: a face wired to the window
      // would move both, and would look right with one group.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final faces = container.read(terminalFacesProvider.notifier);

      faces.show('a', terminal: false);

      expect(container.read(terminalVisibleInGroupProvider('a')), isFalse);
      expect(
        container.read(terminalVisibleInGroupProvider('b')),
        isTrue,
        reason: 'the neighbour is still on its terminal',
      );
      expect(container.read(anyChatVisibleProvider), isTrue);
    });

    test('a group that collapses takes its face with it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final faces = container.read(terminalFacesProvider.notifier);
      faces
        ..show('a', terminal: false)
        ..show('b', terminal: false);

      faces.forget({'a'});

      expect(container.read(terminalFacesProvider).keys, ['a']);
    });
  });
}
