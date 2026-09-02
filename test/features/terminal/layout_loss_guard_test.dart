import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_layout_dao.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// Loop 48 §7: one real run in ten restored 8 tabs and reported `tabs=0` at
/// quit, and because `saveLayout` is a destructive full replace, the stored
/// workspace was erased. The trigger was never found — so the guard is written
/// against the *shape* of the failure rather than its cause: a save that would
/// replace a non-empty stored workspace with an empty one may only happen when
/// the user is the one who emptied it.
void main() {
  group('an empty save nobody asked for', () {
    test('is refused, and the stored workspace survives', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      // A stored workspace the user has, in a pane the app can no longer
      // rebuild — the one deterministic way to reach "the store holds tabs and
      // the controller has none" without a user closing anything.
      final dao = TerminalLayoutDao(db);
      dao.saveLayout([
        StoredTerminalTab(
          id: 'tab-1',
          layout: PaneLayout.single('pane-1'),
          focusedPaneId: 'pane-1',
          panes: const [
            StoredTerminalPane(
              id: 'pane-1',
              tabId: 'tab-1',
              // A profile no build of the app resolves, so the pane — and with
              // it the only tab — is dropped during restore.
              profileId: 'a-shell-this-build-no-longer-has',
              title: 'Something that was installed once',
              workingDirectory: null,
              scrollback: 'work the user has not finished',
            ),
          ],
        ),
      ], activeTabId: 'tab-1');
      expect(dao.storedTabCount(), 1);

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        isEmpty,
        reason: 'the pane could not be rebuilt, so nothing was restored',
      );

      // This is the quit-time save. Before the guard it wrote nothing over
      // something.
      controller.persistLayout();

      expect(
        dao.storedTabCount(),
        1,
        reason:
            'the stored workspace must outlive a restore that found nothing',
      );
      expect(
        dao.loadLayout().tabs.single.panes.single.scrollback,
        'work the user has not finished',
      );
    });

    test('stops being refused once the user has closed something', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);
      dao.saveLayout([
        StoredTerminalTab(
          id: 'tab-1',
          layout: PaneLayout.single('pane-1'),
          focusedPaneId: 'pane-1',
          panes: const [
            StoredTerminalPane(
              id: 'pane-1',
              tabId: 'tab-1',
              profileId: 'a-shell-this-build-no-longer-has',
              title: 'Something that was installed once',
              workingDirectory: null,
              scrollback: 'stale',
            ),
          ],
        ),
      ], activeTabId: 'tab-1');

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      // The guard is armed: restore found nothing and the store is not empty.
      controller.persistLayout();
      expect(dao.storedTabCount(), 1);

      // The user opens a tab and ends it. Now an empty workspace is something
      // they asked for, and the unrestorable row goes with it.
      final tabId = controller.openTab(TerminalProfile.powerShell);
      controller.closeTab(tabId, detach: false);

      expect(dao.storedTabCount(), 0);
      expect(dao.loadBackup().tabs, isNotEmpty);
    });
  });

  group('an empty save the user caused', () {
    test('still clears the stored workspace', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      expect(dao.storedTabCount(), 1);

      // Closing detaches (keep-alive), so the session is still stored; ending
      // it is what empties the workspace. Both are user actions.
      controller.closeTab(tabId);
      controller.endAllDetached();

      expect(dao.storedTabCount(), 0);
    });

    test('leaves the outgoing workspace in the backup tables', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final tabId = controller.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      controller.instanceFor(paneId)!.terminal.write('one irreplaceable line');
      controller.persistLayout();

      controller.closeTab(tabId, detach: false);

      expect(dao.storedTabCount(), 0);
      final backup = dao.loadBackup();
      expect(backup.tabs.single.id, tabId);
      expect(
        backup.tabs.single.panes.single.scrollback,
        contains('one irreplaceable line'),
      );
      expect(db.readMetadata(kTerminalLayoutBackupAtKey), isNotNull);
    });
  });

  group('the backup', () {
    late AppDatabase db;
    late TerminalLayoutDao dao;

    setUp(() {
      db = AppDatabase.memory();
      dao = TerminalLayoutDao(db);
    });
    tearDown(() => db.close());

    StoredTerminalTab tab(String id) => StoredTerminalTab(
      id: id,
      layout: PaneLayout.single('$id-p'),
      focusedPaneId: '$id-p',
      panes: [
        StoredTerminalPane(
          id: '$id-p',
          tabId: id,
          profileId: 'powershell',
          title: 'PowerShell',
          workingDirectory: null,
          scrollback: 'from $id',
        ),
      ],
    );

    test('the schema carries the backup tables', () {
      expect(db.schemaVersion, greaterThanOrEqualTo(11));
      final tables = db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN "
        "('terminal_tabs_backup', 'terminal_panes_backup');",
      );
      expect(tables.length, 2);
    });

    test('is not taken when the save is not an emptying one', () {
      dao.saveLayout([tab('a')], activeTabId: 'a');
      dao.saveLayout([tab('b')], activeTabId: 'b');
      expect(dao.loadBackup().tabs, isEmpty);
      expect(db.readMetadata(kTerminalLayoutBackupAtKey), isNull);
    });

    test('is not taken when there was nothing stored to lose', () {
      dao.saveLayout(const []);
      expect(dao.loadBackup().tabs, isEmpty);
      expect(db.readMetadata(kTerminalLayoutBackupAtKey), isNull);
    });

    test('is taken when a save shrinks a workspace nobody closed', () {
      dao.saveLayout([tab('a'), tab('b')], activeTabId: 'a');
      // One tab where two were stored, and nothing the user did explains it.
      dao.saveLayout([tab('c')], activeTabId: 'c');

      final backup = dao.loadBackup();
      expect(backup.tabs.map((t) => t.id), ['a', 'b']);
      expect(dao.loadLayout().tabs.single.id, 'c');
    });

    test('is not taken when the user is the one closing tabs', () {
      dao.saveLayout([tab('a'), tab('b')], activeTabId: 'a');
      dao.saveLayout([tab('a')], activeTabId: 'a', userClosed: true);
      expect(
        dao.loadBackup().tabs,
        isEmpty,
        reason: 'closing a tab must stay as cheap as it was',
      );
    });

    test('holds only the most recent emptying', () {
      dao.saveLayout([tab('a')], activeTabId: 'a');
      dao.saveLayout(const []);
      dao.saveLayout([tab('b')], activeTabId: 'b');
      dao.saveLayout(const []);

      final backup = dao.loadBackup();
      expect(backup.tabs.single.id, 'b');
      expect(backup.tabs.single.panes.single.scrollback, 'from b');
    });
  });
}
