import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

void main() {
  group('terminalProfileFromId', () {
    test('rebuilds the two host shells', () {
      expect(terminalProfileFromId('powershell'), TerminalProfile.powerShell);
      expect(terminalProfileFromId('cmd'), TerminalProfile.commandPrompt);
    });

    test('rebuilds a WSL profile from its distro', () {
      final profile = terminalProfileFromId('wsl:Ubuntu')!;
      expect(profile.shell, TerminalShell.wsl);
      expect(profile.wslDistribution, 'Ubuntu');
      expect(profile.label, 'Ubuntu (WSL)');
    });

    test('returns null for an id it cannot rebuild', () {
      expect(terminalProfileFromId('nonsense'), isNull);
      expect(terminalProfileFromId('wsl:'), isNull);
    });
  });

  group('layout persistence', () {
    test('a saved layout comes back as tabs, panes and scrollback', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(layoutStore: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
      );
      final second = controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;
      controller.instanceFor(second)!.terminal.write('hello from the past\r\n');
      controller.persistLayout();
      first.dispose();

      // With the launch restart off, which is the shape this test is about:
      // what the *store* round-trips, uncoloured by what is then done with it.
      // That a live pane comes back live is `pane_restart_on_launch_test.dart`.
      final next = fakeTerminalContainer(
        layoutStore: db,
        restoreLivePanes: false,
      );
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      final restoredController = next.read(
        terminalSessionsControllerProvider.notifier,
      );

      expect(restored.tabs.length, 1);
      expect(restored.tabs.single.layout.panes.length, 2);
      expect(restored.activeTabId, restored.tabs.single.id);

      final panes = restored.tabs.single.layout.panes;
      final replayed = [
        for (final pane in panes)
          (restoredController.instanceFor(pane)! as DormantTerminalInstance)
              .restoredScrollback,
      ];
      expect(replayed.join(), contains('hello from the past'));

      // Nothing was started: a pane the launch does not restart is a record,
      // and re-running what was in it is the user's call, not the app's.
      for (final pane in panes) {
        expect(restored.livenessOf(pane), PaneLiveness.restored);
      }

      // The relaunch data survives too, or the pane would come back wrong.
      final firstPane = restoredController.instanceFor(panes.first)!;
      expect(firstPane.profileId, 'powershell');
      expect(firstPane.workingDirectory, r'C:\ws');
    });

    test('a corrupt stored layout falls back to no tabs, not a crash', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);
      db.execute(
        'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
        'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
        ['bad', 0, 'not-json', null, 1, '2026-01-01T00:00:00.000Z'],
      );

      final container = fakeTerminalContainer(layoutStore: db);
      addTearDown(container.dispose);
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    });

    test(
      'a pane whose profile no longer resolves is dropped, tab survives',
      () {
        final db = TerminalLayoutStore.memory();
        addTearDown(db.close);

        final first = fakeTerminalContainer(layoutStore: db);
        final controller = first.read(
          terminalSessionsControllerProvider.notifier,
        );
        controller.openTab(TerminalProfile.powerShell);
        controller.splitPaneWith(
          SplitAxis.horizontal,
          TerminalProfile.commandPrompt,
        );
        controller.persistLayout();
        first.dispose();

        // Corrupt one pane's profile so it cannot be rebuilt.
        final paneId =
            db
                    .query('SELECT id FROM terminal_panes ORDER BY ordinal;')
                    .last['id']
                as String;
        db.execute('UPDATE terminal_panes SET profile_id = ? WHERE id = ?;', [
          'gone',
          paneId,
        ]);

        final next = fakeTerminalContainer(layoutStore: db);
        addTearDown(next.dispose);
        final restored = next.read(terminalSessionsControllerProvider);
        expect(restored.tabs.length, 1);
        expect(restored.tabs.single.layout.panes.length, 1);
      },
    );

    test('with no database at all the terminal still opens', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
      // Neither restoring nor persisting may throw when there is no database.
      controller.openTab(TerminalProfile.powerShell);
      controller.persistLayout();
      expect(container.read(terminalSessionsControllerProvider).tabs.length, 1);
    });

    test('closing every tab clears the stored layout', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final container = fakeTerminalContainer(layoutStore: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      // A shell with history: an idle one would be released on close, and this
      // test is about what a *detached* session does to the stored layout.
      giveShellHistory(
        controller.instanceFor(
          container
              .read(terminalSessionsControllerProvider)
              .activeTab!
              .layout
              .panes
              .single,
        )!,
      );
      controller.persistLayout();
      expect(db.query('SELECT id FROM terminal_tabs;'), isNotEmpty);

      // Closing the tab detaches the session, so it is still stored — as a
      // background session rather than a tab.
      controller.closeTab(tabId);
      controller.persistLayout();
      expect(
        db.query('SELECT detached FROM terminal_tabs;').single['detached'],
        1,
      );

      // Ending it is what actually clears the layout.
      controller.endAllDetached();
      expect(db.query('SELECT id FROM terminal_tabs;'), isEmpty);
    });

    test('autosave writes only the panes whose buffers changed', () {
      final db = TerminalLayoutStore.memory();
      addTearDown(db.close);

      final container = fakeTerminalContainer(layoutStore: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final quiet = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      final busy = controller.splitPaneWith(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;
      controller.persistLayout();

      controller.instanceFor(busy)!.terminal.write('new output\r\n');
      final written = controller.saveDirtyScrollback();

      expect(written, [busy]);
      final rows = db.query(
        'SELECT id, scrollback FROM terminal_panes WHERE id = ?;',
        [busy],
      );
      expect(rows.single['scrollback'], contains('new output'));
      expect(
        controller.saveDirtyScrollback(),
        isEmpty,
        reason: 'nothing changed since the last save',
      );
      expect(quiet, isNotEmpty);
    });
  });
}
