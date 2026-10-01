import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:xterm2/xterm.dart';

import 'fake_instance.dart';

/// Panes that were running when the app closed come back running.
///
/// The owner, twice: *"why when app restart the active pane doesn't
/// automatically resume the session? why must i tap start again"*, and *"if
/// there were active panes on last close start all those panes on active tab"*.
///
/// What these pin is not only that it happens, but the four things it
/// deliberately does **not** do — see `pane_restart.dart` for the argument
/// behind each one.
void main() {
  _restoreOnActivateTests();

  group('shouldRestartOnLaunch', () {
    test('a live shell in the active tab starts', () {
      expect(
        shouldRestartOnLaunch(
          enabled: true,
          wasLive: true,
          inActiveTab: true,
          isAgentPane: false,
        ),
        isTrue,
      );
    });

    test('every one of the four conditions can refuse on its own', () {
      for (final refused in [
        (enabled: false, wasLive: true, inActiveTab: true, isAgentPane: false),
        (enabled: true, wasLive: false, inActiveTab: true, isAgentPane: false),
        (enabled: true, wasLive: true, inActiveTab: false, isAgentPane: false),
        (enabled: true, wasLive: true, inActiveTab: true, isAgentPane: true),
      ]) {
        expect(
          shouldRestartOnLaunch(
            enabled: refused.enabled,
            wasLive: refused.wasLive,
            inActiveTab: refused.inActiveTab,
            isAgentPane: refused.isAgentPane,
          ),
          isFalse,
          reason: '$refused should not start on its own',
        );
      }
    });
  });

  group('shouldResumeRatherThanRestart', () {
    test('only a restored agent pane resumes', () {
      expect(
        shouldResumeRatherThanRestart(
          liveness: PaneLiveness.restored,
          isAgentPane: true,
        ),
        isTrue,
      );
    });

    test('a shell is re-run in both states, and so is a dead agent', () {
      for (final kept in [
        (liveness: PaneLiveness.restored, isAgentPane: false),
        (liveness: PaneLiveness.exited, isAgentPane: false),
        (liveness: PaneLiveness.exited, isAgentPane: true),
        (liveness: PaneLiveness.live, isAgentPane: true),
      ]) {
        expect(
          shouldResumeRatherThanRestart(
            liveness: kept.liveness,
            isAgentPane: kept.isAgentPane,
          ),
          isFalse,
          reason: '$kept re-runs what it recorded',
        );
      }
    });
  });

  group('a pane that was live at close', () {
    test('comes back running, with its history above the new process', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final paneId = _closeWith(db, (container, controller) {
        controller.openTab(
          TerminalProfile.powerShell,
          workingDirectory: r'C:\ws',
        );
      }).single;

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      final instance = next
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId)!;

      expect(restored.livenessOf(paneId), PaneLiveness.live);
      expect(
        (instance as FakeTerminalInstance).restored,
        contains('hello from the past'),
        reason: 'a restarted pane replays what it had, it does not start blank',
      );
      expect(instance.workingDirectory, r'C:\ws');
    });

    test('is not restarted when the setting is off', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final paneId = _closeWith(db, (container, controller) {
        controller.openTab(TerminalProfile.powerShell);
      }).single;

      final next = fakeTerminalContainer(
        layoutStore: db,
        restoreLivePanes: false,
      );
      addTearDown(next.dispose);
      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.restored,
      );
    });
  });

  group('a pane that was not running at close', () {
    test('one whose process had already exited stays a record', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final paneId = _closeWith(db, (container, controller) {
        final id = controller.openTab(TerminalProfile.powerShell);
        final pane = controller.instanceFor(_panesOfTab(container, id).single)!;
        (pane as FakeTerminalInstance).exitWith(1);
      }).single;

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.restored,
      );
    });

    test('one the user never started stays a record over two restarts', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      // Closed while dead, so the first restore leaves it dormant...
      final paneId = _closeWith(db, (container, controller) {
        final id = controller.openTab(TerminalProfile.powerShell);
        (controller.instanceFor(_panesOfTab(container, id).single)!
                as FakeTerminalInstance)
            .exitWith(1);
      }).single;

      // ...and that dormant pane's own save must not claim it was running,
      // or the second launch would start what the first correctly did not.
      final second = fakeTerminalContainer(layoutStore: db);
      expect(
        second.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.restored,
      );
      second.dispose();

      final third = fakeTerminalContainer(layoutStore: db);
      addTearDown(third.dispose);
      expect(
        third.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.restored,
      );
    });
  });

  group('scope', () {
    test('only the tab that was active starts; the others keep their Start', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      late String background;
      late String foreground;
      _closeWith(db, (container, controller) {
        background = _panesOfTab(
          container,
          controller.openTab(TerminalProfile.powerShell),
        ).single;
        // The second tab is the active one, which is what the owner asked for:
        // "start all those panes on active tab".
        foreground = _panesOfTab(
          container,
          controller.openTab(TerminalProfile.commandPrompt),
        ).single;
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      expect(restored.livenessOf(foreground), PaneLiveness.live);
      expect(restored.livenessOf(background), PaneLiveness.restored);
    });

    test('every pane of the active tab starts, not only the focused one', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final panes = _closeWith(db, (container, controller) {
        controller.openTab(TerminalProfile.powerShell);
        controller.splitPaneWith(
          SplitAxis.horizontal,
          TerminalProfile.commandPrompt,
        );
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      expect(panes.length, 2);
      for (final pane in panes) {
        expect(restored.livenessOf(pane), PaneLiveness.live);
      }
    });

    test('a closed tab is not started — it is not restored at all', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      late String paneId;
      _closeWith(db, (container, controller) {
        final tabId = controller.openTab(TerminalProfile.powerShell);
        paneId = _panesOfTab(container, tabId).single;
        // History once kept it alive with no tab; closing drops it now.
        giveShellHistory(controller.instanceFor(paneId)!);
        controller.closeTab(tabId);
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      expect(restored.detached, isEmpty);
      expect(restored.liveness, isNot(contains(paneId)));
      expect(
        next
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(paneId),
        isNull,
      );
    });
  });

  group('an agent pane', () {
    /// A live agent pane and a live shell, both in the active tab, at close.
    List<String> closeWithAnAgentAndAShell(TerminalLayoutStore db) =>
        _closeWith(db, (container, controller) {
          controller.openAgentTab(
            const AgentPaneLaunch(
              agentId: 'claudeCode',
              executable: '/usr/bin/claude',
              workingDirectory: '/home/dev/repo',
              title: 'a conversation',
            ),
          );
          controller.splitPaneWith(
            SplitAxis.horizontal,
            TerminalProfile.powerShell,
          );
        });

    test('never starts itself, while the shell beside it does', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);
      final panes = closeWithAnAgentAndAShell(db);

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      final controller = next.read(terminalSessionsControllerProvider.notifier);
      final agent = panes.firstWhere(
        (id) => controller.instanceFor(id)!.agentLaunch != null,
      );
      final shell = panes.firstWhere((id) => id != agent);

      expect(
        restored.livenessOf(agent),
        PaneLiveness.restored,
        reason:
            'starting an agent pane re-runs its recorded command line — tokens '
            'and tools, unasked — and takes the pane a proper resume needs',
      );
      expect(restored.livenessOf(shell), PaneLiveness.live);
    });

    test('is equally not started with the setting off', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);
      final panes = closeWithAnAgentAndAShell(db);

      final next = fakeTerminalContainer(
        layoutStore: db,
        restoreLivePanes: false,
      );
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      for (final pane in panes) {
        expect(restored.livenessOf(pane), PaneLiveness.restored);
      }
    });
  });

  group('a pane that cannot start', () {
    test('says so, rather than looking like a shell waiting for input', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);
      final paneId = _closeWith(db, (container, controller) {
        controller.openTab(TerminalProfile.powerShell);
      }).single;

      final next = ProviderContainer(
        overrides: fakeTerminalOverrides(
          layoutStore: db,
          instanceFactory: _failedSpawnFactory,
        ),
      );
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      final instance = next
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId)!;

      expect(restored.livenessOf(paneId), PaneLiveness.exited);
      expect(instance, isA<ErrorTerminalInstance>());
      expect(
        instance.terminal.buffer.getText(),
        contains('the distro is not running'),
      );
      expect(
        instance.terminal.buffer.getText(),
        contains('hello from the past'),
        reason: 'a failed restart still holds the history worth retrying for',
      );
    });

    test(
      'a factory that throws costs the pane its process, not the layout',
      () {
        final db = TerminalLayoutStore.memory();
        addTearDown(db.close);
        final paneId = _closeWith(db, (container, controller) {
          controller.openTab(TerminalProfile.powerShell);
        }).single;

        final next = ProviderContainer(
          overrides: fakeTerminalOverrides(
            layoutStore: db,
            instanceFactory: _throwingFactory,
          ),
        );
        addTearDown(next.dispose);
        final restored = next.read(terminalSessionsControllerProvider);

        expect(restored.tabs.single.layout.panes, [paneId]);
        expect(restored.livenessOf(paneId), PaneLiveness.restored);
      },
    );
  });
}

/// Runs [body] against a fresh layout over [db], leaves a line of history in
/// every pane it opened, and closes the app on it. Returns the panes of the tab
/// that was active, in layout order.
///
/// The history matters: it is what a restart has to replay, and
/// `shouldDetachOnClose` only keeps a pane that has some.
/// The other half of the rule: a tab that was not active at launch.
///
/// The launch rule stops at the active tab to avoid spawning shells nobody is
/// looking at. That left every other tab with a Start button forever — so the
/// answer to "why must I press Start?" was "because this was not the active tab
/// when the app opened", which is not a reason anyone can see. Opening the tab
/// is the moment that condition was standing in for.
void _restoreOnActivateTests() {
  group('a background tab', () {
    test('starts what it was left running, when it is opened', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      late String background;
      late String backgroundTab;
      _closeWith(db, (container, controller) {
        backgroundTab = controller.openTab(TerminalProfile.powerShell);
        background = _panesOfTab(container, backgroundTab).single;
        // A second tab, so the first is not the one left in front.
        controller.openTab(TerminalProfile.commandPrompt);
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      expect(
        restored.livenessOf(background),
        PaneLiveness.restored,
        reason: 'still history while nobody has looked at it',
      );

      next
          .read(terminalSessionsControllerProvider.notifier)
          .activateTab(backgroundTab);

      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(background),
        PaneLiveness.live,
      );
    });

    test('costs nothing while nobody opens it', () {
      // The whole reason the launch rule stopped at the active tab.
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      late String background;
      _closeWith(db, (container, controller) {
        background = _panesOfTab(
          container,
          controller.openTab(TerminalProfile.powerShell),
        ).single;
        controller.openTab(TerminalProfile.commandPrompt);
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);

      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(background),
        PaneLiveness.restored,
      );
    });

    test('still never starts an agent pane', () {
      // The reason the launch rule excludes them holds just as well here:
      // starting one re-runs its recorded command — tokens spent and tools run
      // because a tab was clicked — and steals the pane a proper `--resume` is
      // looking for.
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      late String agentPane;
      late String tabId;
      _closeWith(db, (container, controller) {
        final opened = controller.openAgentTab(
          const AgentPaneLaunch(
            agentId: 'claudeCode',
            executable: '/usr/bin/claude',
            workingDirectory: '/home/dev/repo',
            title: 'a conversation',
          ),
        );
        tabId = opened.tabId;
        agentPane = opened.paneId;
        controller.openTab(TerminalProfile.commandPrompt);
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      next.read(terminalSessionsControllerProvider.notifier).activateTab(tabId);

      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(agentPane),
        PaneLiveness.restored,
      );
    });

    test('does not start a pane the user had already stopped', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      late String pane;
      late String tabId;
      _closeWith(db, (container, controller) {
        tabId = controller.openTab(TerminalProfile.powerShell);
        pane = _panesOfTab(container, tabId).single;
        // Left as a record on purpose: nothing was running here at close.
        (controller.instanceFor(pane)! as FakeTerminalInstance).exitWith(1);
        controller.openTab(TerminalProfile.commandPrompt);
      });

      final next = fakeTerminalContainer(layoutStore: db);
      addTearDown(next.dispose);
      next.read(terminalSessionsControllerProvider.notifier).activateTab(tabId);

      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(pane),
        isNot(PaneLiveness.live),
      );
    });
  });
}

List<String> _closeWith(
  TerminalLayoutStore db,
  void Function(
    ProviderContainer container,
    TerminalSessionsController controller,
  )
  body,
) {
  final container = fakeTerminalContainer(layoutStore: db);
  final controller = container.read(
    terminalSessionsControllerProvider.notifier,
  );
  body(container, controller);
  for (final tab in container.read(terminalSessionsControllerProvider).tabs) {
    for (final paneId in tab.layout.panes) {
      final instance = controller.instanceFor(paneId);
      if (instance == null || !instance.liveness.value.isLive) continue;
      instance.terminal.write('hello from the past\r\n');
    }
  }
  final state = container.read(terminalSessionsControllerProvider);
  final active = state.activeTab?.layout.panes ?? const <String>[];
  controller.persistLayout();
  // Disposing the container is the app quitting: the teardown save is the one
  // that has to record what was still running.
  container.dispose();
  return active;
}

/// The panes of one tab, in layout order — what a test means by "that tab".
List<String> _panesOfTab(ProviderContainer container, String tabId) {
  for (final tab in container.read(terminalSessionsControllerProvider).tabs) {
    if (tab.id == tabId) return tab.layout.panes;
  }
  return const [];
}

/// A factory that fails exactly the way a real one does when the shell will not
/// spawn: an [ErrorTerminalInstance] holding the reason and the history.
TerminalInstance _failedSpawnFactory({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
}) => ErrorTerminalInstance(
  id: id,
  title: profile.label,
  profileId: profile.id,
  workingDirectory: workingDirectory,
  agentLaunch: agentLaunch,
  restoredScrollback: restoredScrollback,
  adoptTerminal: adoptTerminal,
  message: 'Failed to start "wsl.exe": the distro is not running',
);

/// A factory that throws instead of degrading — the case nothing in production
/// should produce, and which must still not take the layout down.
TerminalInstance _throwingFactory({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
}) => throw StateError('no pty here');
