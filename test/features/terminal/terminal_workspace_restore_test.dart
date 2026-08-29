import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
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

  group('workspace persistence', () {
    test('a saved workspace comes back as tabs, panes and scrollback', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell, workingDirectory: r'C:\ws');
      final second = controller.splitPane(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;
      controller.instanceFor(second)!.terminal.write('hello from the past\r\n');
      controller.persistWorkspace();
      first.dispose();

      final next = fakeTerminalContainer(database: db);
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
          (restoredController.instanceFor(pane)! as FakeTerminalInstance)
                  .restored ??
              '',
      ];
      expect(replayed.join(), contains('hello from the past'));

      // The relaunch data survives too, or the pane would come back wrong.
      final firstPane = restoredController.instanceFor(panes.first)!;
      expect(firstPane.profileId, 'powershell');
      expect(firstPane.workingDirectory, r'C:\ws');
    });

    test('a corrupt stored layout falls back to no tabs, not a crash', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      db.execute(
        'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
        'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
        ['bad', 0, 'not-json', null, 1, '2026-01-01T00:00:00.000Z'],
      );

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    });

    test('a pane whose profile no longer resolves is dropped, tab survives', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = fakeTerminalContainer(database: db);
      final controller = first.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      controller.splitPane(SplitAxis.horizontal, TerminalProfile.commandPrompt);
      controller.persistWorkspace();
      first.dispose();

      // Corrupt one pane's profile so it cannot be rebuilt.
      final paneId =
          db.query('SELECT id FROM terminal_panes ORDER BY ordinal;').last['id']
              as String;
      db.execute('UPDATE terminal_panes SET profile_id = ? WHERE id = ?;', [
        'gone',
        paneId,
      ]);

      final next = fakeTerminalContainer(database: db);
      addTearDown(next.dispose);
      final restored = next.read(terminalSessionsControllerProvider);
      expect(restored.tabs.length, 1);
      expect(restored.tabs.single.layout.panes.length, 1);
    });

    test('with no database at all the terminal still opens', () {
      final container = fakeTerminalContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
      // Neither restoring nor persisting may throw when there is no database.
      controller.openTab(TerminalProfile.powerShell);
      controller.persistWorkspace();
      expect(container.read(terminalSessionsControllerProvider).tabs.length, 1);
    });

    test('closing every tab clears the stored workspace', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      controller.persistWorkspace();
      expect(db.query('SELECT id FROM terminal_tabs;'), isNotEmpty);

      controller.closeTab(tabId);
      controller.persistWorkspace();
      expect(db.query('SELECT id FROM terminal_tabs;'), isEmpty);
    });

    test('autosave writes only the panes whose buffers changed', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final container = fakeTerminalContainer(database: db);
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
      final busy = controller.splitPane(
        SplitAxis.horizontal,
        TerminalProfile.commandPrompt,
      )!;
      controller.persistWorkspace();

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
