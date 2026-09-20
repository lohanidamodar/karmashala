import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Session lifetime is not view lifetime.
///
/// Closing a tab is a statement about the window, not about the build, dev
/// server or agent running inside it. These tests pin that split: what survives
/// a closed tab, what genuinely ends a session, and what a restart can and
/// cannot bring back.
void main() {
  group('keep-alive', () {
    test('a detached session can be re-attached to a new tab', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(pane)!;
      giveShellHistory(instance);

      controller.closeTab(tabId);
      final reattached = controller.reattachSession(pane);

      final state = container.read(terminalSessionsControllerProvider);
      expect(state.detached, isEmpty);
      expect(state.tabs.single.id, reattached);
      expect(state.tabs.single.layout.panes, [pane]);
      // The same object, so nothing had to be recreated and no output was lost.
      expect(controller.instanceFor(pane), same(instance));
      expect(state.livenessOf(pane), PaneLiveness.live);
    });

    test('re-attaching an unknown pane does nothing', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(controller.reattachSession('nope'), isNull);
    });

    test('ending a detached session disposes it for real', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;

      controller.closeTab(tabId);
      controller.endSession(pane);

      expect(instance.disposed, isTrue);
      expect(controller.instanceFor(pane), isNull);
      expect(container.read(terminalSessionsControllerProvider).detached, []);
    });

    test('ending a session that still has a tab closes the tab too', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(pane)! as FakeTerminalInstance;

      controller.endSession(pane);

      final state = container.read(terminalSessionsControllerProvider);
      expect(instance.disposed, isTrue, reason: 'ending is not detaching');
      expect(state.tabs, isEmpty);
      expect(state.detached, isEmpty);
    });

    test('endAllDetached clears every background session', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final first = controller.openTab(TerminalProfile.powerShell);
      final second = controller.openTab(TerminalProfile.commandPrompt);
      for (final tab
          in container.read(terminalSessionsControllerProvider).tabs) {
        giveShellHistory(controller.instanceFor(tab.layout.panes.single)!);
      }
      controller
        ..closeTab(first)
        ..closeTab(second);
      expect(
        container.read(terminalSessionsControllerProvider).detached.length,
        2,
      );

      controller.endAllDetached();

      expect(container.read(terminalSessionsControllerProvider).detached, []);
    });

    test('a pane with no process left is dropped, not detached', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      // The shell exited on its own — the user typed `exit`, or it crashed.
      (controller.instanceFor(pane)! as FakeTerminalInstance)
              .livenessNotifier
              .value =
          PaneLiveness.exited;

      controller.closeTab(tabId);

      expect(
        container.read(terminalSessionsControllerProvider).detached,
        isEmpty,
        reason: 'keep-alive protects running work; there was none here',
      );
      expect(controller.instanceFor(pane), isNull);
    });

    test('a process exiting republishes its pane as no longer live', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      expect(
        container.read(terminalSessionsControllerProvider).livenessOf(pane),
        PaneLiveness.live,
      );
      expect(
        controller.livenessForTab(controller.state.tabs.single.id),
        PaneLiveness.live,
      );

      (controller.instanceFor(pane)! as FakeTerminalInstance)
              .livenessNotifier
              .value =
          PaneLiveness.exited;

      expect(
        container.read(terminalSessionsControllerProvider).livenessOf(pane),
        PaneLiveness.exited,
      );
    });

    test('a split reads as live while any one pane still is', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final second = controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;

      (controller.instanceFor(second)! as FakeTerminalInstance)
              .livenessNotifier
              .value =
          PaneLiveness.exited;

      expect(controller.livenessForTab(tabId), PaneLiveness.live);
    });
  });

  group('starting a pane', () {
    test('a restored pane starts nothing until asked, then runs', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell, workingDirectory: r'C:\a');
      final pane = first
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      controller.instanceFor(pane)!.terminal.write('yesterday\r\n');
      controller.persistLayout();
      first.dispose();

      // This is about the Start button, so the pane has to be one that did not
      // start itself. Every pane a launch declines — an agent pane, a
      // background tab, a pane whose process had already exited, or any pane at
      // all with this setting off — arrives in exactly this state and is
      // started by exactly this call. See `pane_restart_on_launch_test.dart`.
      final next = fakeTerminalContainer(database: db, restoreLivePanes: false);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider.notifier);
      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(pane),
        PaneLiveness.restored,
      );
      expect(restored.instanceFor(pane), isA<DormantTerminalInstance>());

      restored.startPane(pane);

      final started = restored.instanceFor(pane)! as FakeTerminalInstance;
      expect(
        next.read(terminalSessionsControllerProvider).livenessOf(pane),
        PaneLiveness.live,
      );
      // It starts where it left off: same profile, same directory, same history.
      expect(started.profileId, 'powershell');
      expect(started.workingDirectory, r'C:\a');
      expect(started.restored, contains('yesterday'));
    });

    test('starting a live pane is a no-op', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final instance = controller.instanceFor(pane)!;

      controller.startPane(pane);

      expect(controller.instanceFor(pane), same(instance));
    });

    test('a pane whose process exited restarts with its buffer kept', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final dead = controller.instanceFor(pane)! as FakeTerminalInstance;
      dead.terminal.write('output before it died\r\n');
      dead.livenessNotifier.value = PaneLiveness.exited;

      controller.startPane(pane);

      final restarted = controller.instanceFor(pane)! as FakeTerminalInstance;
      expect(restarted, isNot(same(dead)));
      expect(dead.disposed, isTrue);
      // The buffer is handed over rather than encoded out and parsed back in —
      // see `resume_cost_test.dart` for the count that makes that the point.
      // What the user is owed is the history, and it is the same history.
      expect(restarted.adopted, same(dead.terminal));
      expect(
        restarted.terminal.mainBuffer.getText(),
        contains('output before it died'),
      );
    });
  });

  /// Resuming a session it already has a pane for.
  ///
  /// [TerminalSessionsController.startPane] re-runs what the pane recorded,
  /// which is the retry a user asks for from the pane itself. A session being
  /// resumed needs the other half: a *different* command line — the resume one
  /// — run in the buffer the pane kept, because the alternative is a second
  /// pane for a session that already has one.
  group('resuming into an existing pane', () {
    test('a dormant agent pane runs the command it is given, above what it '
        'kept', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'sharing',
          executable: 'sharing',
          arguments: ['--session-id', 'sess-1'],
          workingDirectory: r'C:\ws',
          sessionId: 'sess-1',
          title: 'Earlier work',
        ),
      );
      controller.instanceFor(opened.paneId)!.terminal.write('yesterday\r\n');
      controller.persistLayout();
      first.dispose();

      final next = fakeTerminalContainer(database: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider.notifier);
      expect(
        restored.instanceFor(opened.paneId),
        isA<DormantTerminalInstance>(),
      );

      final tabId = restored.startAgentInPane(
        opened.paneId,
        const AgentPaneLaunch(
          agentId: 'sharing',
          executable: 'sharing',
          arguments: ['--resume', 'ext-1'],
          workingDirectory: r'C:\ws',
          sessionId: 'sess-1',
        ),
      );

      final state = next.read(terminalSessionsControllerProvider);
      // The pane it already had, in the tab it was already in.
      expect(tabId, state.tabs.single.id);
      expect(state.tabs.single.layout.panes, [opened.paneId]);
      expect(state.livenessOf(opened.paneId), PaneLiveness.live);

      final started =
          restored.instanceFor(opened.paneId)! as FakeTerminalInstance;
      // The resume command, not the one the pane recorded — re-running that
      // would start a new conversation rather than continue the stored one.
      expect(started.agentLaunch!.arguments, ['--resume', 'ext-1']);
      // And the scrollback that was the whole reason to keep the pane.
      expect(started.restored, contains('yesterday'));
    });

    test('a dormant pane left in the background comes back as a tab', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'sharing',
          executable: 'sharing',
          sessionId: 'sess-1',
        ),
      );
      controller.closeTab(opened.tabId);
      controller.persistLayout();
      first.dispose();

      final next = fakeTerminalContainer(database: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider.notifier);
      expect(
        next.read(terminalSessionsControllerProvider).detached,
        hasLength(1),
      );

      final tabId = restored.startAgentInPane(
        opened.paneId,
        const AgentPaneLaunch(
          agentId: 'sharing',
          executable: 'sharing',
          arguments: ['--resume', 'ext-1'],
          sessionId: 'sess-1',
        ),
      );

      final state = next.read(terminalSessionsControllerProvider);
      expect(state.detached, isEmpty);
      expect(state.tabs.single.id, tabId);
      expect(state.activeTabId, tabId);
      expect(state.tabs.single.layout.panes, [opened.paneId]);
    });

    test('a pane that is not there refuses, so the caller opens its own', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);

      expect(
        container
            .read(terminalSessionsControllerProvider.notifier)
            .startAgentInPane(
              'no-such-pane',
              const AgentPaneLaunch(agentId: 'sharing', executable: 'sharing'),
            ),
        isNull,
      );
    });

    test('a pane something is still running in refuses, rather than killing '
        'it', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'sharing',
          executable: 'sharing',
          sessionId: 'sess-1',
        ),
      );
      final live = controller.instanceFor(opened.paneId)!;

      expect(
        controller.startAgentInPane(
          opened.paneId,
          const AgentPaneLaunch(
            agentId: 'sharing',
            executable: 'sharing',
            arguments: ['--resume', 'ext-1'],
          ),
        ),
        isNull,
      );
      expect(controller.instanceFor(opened.paneId), same(live));
      expect((live as FakeTerminalInstance).disposed, isFalse);
    });
  });

  group('restore', () {
    test('detached sessions come back as background sessions, not tabs', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      final kept = controller.openTab(TerminalProfile.powerShell);
      final closed = controller.openTab(TerminalProfile.commandPrompt);
      final backgroundPane = first
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((t) => t.id == closed)
          .layout
          .panes
          .single;
      giveShellHistory(controller.instanceFor(backgroundPane)!);
      controller
          .instanceFor(backgroundPane)!
          .terminal
          .write('a long build\r\n');
      controller.closeTab(closed);
      controller.persistLayout();
      first.dispose();

      final next = fakeTerminalContainer(database: db);
      addTearDown(next.dispose);
      final state = next.read(terminalSessionsControllerProvider);

      expect(state.tabs.single.id, kept, reason: 'only the open tab is a tab');
      expect(state.detached.map((s) => s.paneId), [backgroundPane]);
      // A reboot ended the process, so it comes back as history, not a session.
      expect(state.livenessOf(backgroundPane), PaneLiveness.restored);
      expect(
        (next
                    .read(terminalSessionsControllerProvider.notifier)
                    .instanceFor(backgroundPane)!
                as DormantTerminalInstance)
            .restoredScrollback,
        contains('a long build'),
      );
    });

    test('a restored background session can be reopened as a tab', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final pane = first
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      giveShellHistory(controller.instanceFor(pane)!);
      controller.closeTab(tabId);
      controller.persistLayout();
      first.dispose();

      final next = fakeTerminalContainer(database: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider.notifier);

      expect(restored.reattachSession(pane), isNotNull);
      final state = next.read(terminalSessionsControllerProvider);
      expect(state.tabs.single.layout.panes, [pane]);
      expect(state.detached, isEmpty);
      expect(state.livenessOf(pane), PaneLiveness.restored);
    });

    test('opening and splitting persist without waiting for a close', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      addTearDown(first.dispose);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      // No close, no dispose — quitting from the tray destroys the window
      // without disposing the container, so a tab only written on close is a
      // tab that never comes back.
      controller.openTab(TerminalProfile.powerShell);
      controller.splitPaneWith(
        SplitAxis.vertical,
        TerminalProfile.commandPrompt,
      );

      expect(db.query('SELECT id FROM terminal_tabs;').length, 1);
      expect(db.query('SELECT id FROM terminal_panes;').length, 2);
    });
  });
}
