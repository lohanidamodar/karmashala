import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_workspace_dao.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_instance.dart';

/// What a **structural** save costs the database, counted rather than timed.
///
/// The owner's report against 1.1.5 was "resuming session still makes ui
/// laggy". Resume itself had already stopped rebuilding the pane it resumes
/// into (`resume_cost_test.dart`), so the remaining cost was the save that
/// immediately follows: `saveWorkspace` was a destructive full replace —
/// `DELETE FROM terminal_tabs;` and then one INSERT per tab and per pane,
/// each pane carrying its whole scrollback — run on *every* structural change,
/// through synchronous `package:sqlite3` bindings, on the UI isolate.
/// `tool/benchmark/terminal_scale_bench.dart` measured 645 ms at the 100-pane
/// scale target.
///
/// Resuming a session adds one pane to one tab. These tests pin the rule that
/// makes that cost what it says: **a save writes the rows that changed**, and
/// nothing else — so the write cost of one structural change is flat in the
/// size of the workspace, in the shape `scale_curve_test.dart` established.
///
/// Counted, not timed, for the reason `attention_inbox_cost_test.dart` gives:
/// a wall-clock assertion over a few milliseconds fails whenever the machine is
/// busy, and the unit that actually matters here — rows written — is countable
/// directly.
void main() {
  /// The three points the curve is read at. One tab is the "did we make the
  /// small case worse" control; a hundred is the scale target.
  const scale = [1, 10, 100];

  StoredTerminalPane pane(
    String tabId,
    String paneId, {
    String scrollback = 'some output',
  }) => StoredTerminalPane(
    id: paneId,
    tabId: tabId,
    profileId: 'powershell',
    title: 'PowerShell',
    workingDirectory: r'C:\ws',
    scrollback: scrollback,
  );

  /// A one-pane tab, the ordinary shape of a restored workspace.
  StoredTerminalTab tab(String id) => StoredTerminalTab(
    id: id,
    layout: PaneLayout.single('$id-p1'),
    focusedPaneId: '$id-p1',
    panes: [pane(id, '$id-p1')],
  );

  /// The same tab after a split — one more pane, one changed layout. This is
  /// the shape of the change a resume makes.
  StoredTerminalTab splitTab(String id) {
    final layout = PaneLayout.single(
      '$id-p1',
    ).split('$id-p1', SplitAxis.horizontal, '$id-p2', '$id-s1');
    return StoredTerminalTab(
      id: id,
      layout: layout,
      focusedPaneId: '$id-p2',
      panes: [pane(id, '$id-p1'), pane(id, '$id-p2', scrollback: '')],
    );
  }

  List<StoredTerminalTab> workspace(int tabs) => [
    for (var i = 0; i < tabs; i++) tab('t$i'),
  ];

  group('the write cost of one structural change', () {
    /// Filled by the cases below so the *shape* can be asserted across them
    /// rather than inside any one of them.
    final rowsWritten = <int, int>{};

    for (final n in scale) {
      test('at $n tabs, adding a pane writes only that pane and its tab', () {
        final db = _CountingDatabase();
        addTearDown(db.close);
        final dao = TerminalWorkspaceDao(db);

        final tabs = workspace(n);
        dao.saveWorkspace(tabs, activeTabId: 't0');

        // One tab gains a pane. Everything else is byte-for-byte what was
        // already stored.
        final grown = [...tabs]..[n - 1] = splitTab('t${n - 1}');
        db.reset();
        dao.saveWorkspace(grown, activeTabId: 't0');

        rowsWritten[n] = db.workspaceWrites;
        expect(
          db.workspaceWrites,
          2,
          reason:
              'the tab whose layout changed, and the pane that appeared — '
              'nothing else moved',
        );
        // The store still says exactly what it was asked to.
        expect(
          dao.loadWorkspace().tabs.last.panes.map((p) => p.id),
          ['t${n - 1}-p1', 't${n - 1}-p2'],
        );
      });
    }

    test('is flat: a hundred tabs cost what one tab costs', () {
      expect(rowsWritten.keys, containsAll(scale));
      expect(
        rowsWritten.values.toSet(),
        hasLength(1),
        reason: 'row writes must not grow with the workspace: $rowsWritten',
      );
    });
  });

  group('a save that changes nothing', () {
    test('writes nothing at all', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalWorkspaceDao(db);
      final tabs = workspace(10);
      dao.saveWorkspace(tabs, activeTabId: 't0');

      db.reset();
      dao.saveWorkspace(tabs, activeTabId: 't0');
      dao.saveWorkspace(tabs, activeTabId: 't0');

      expect(db.workspaceWrites, 0);
    });

    test('is still a save: the store is unchanged, not emptied', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalWorkspaceDao(db);
      dao.saveWorkspace(workspace(3), activeTabId: 't1');
      dao.saveWorkspace(workspace(3), activeTabId: 't1');

      final loaded = dao.loadWorkspace();
      expect(loaded.tabs.map((t) => t.id), ['t0', 't1', 't2']);
      expect(loaded.activeTabId, 't1');
      expect(loaded.tabs.first.panes.single.scrollback, 'some output');
    });
  });

  group('what a full replace got for free', () {
    late _CountingDatabase db;
    late TerminalWorkspaceDao dao;

    setUp(() {
      db = _CountingDatabase();
      dao = TerminalWorkspaceDao(db);
    });
    tearDown(() => db.close());

    test('a removed tab is really deleted, and its panes with it', () {
      dao.saveWorkspace(workspace(3), activeTabId: 't0');
      final kept = [tab('t0'), tab('t2')];

      dao.saveWorkspace(kept, activeTabId: 't0', userClosed: true);

      expect(dao.loadWorkspace().tabs.map((t) => t.id), ['t0', 't2']);
      expect(dao.storedTabCount(), 2);
      expect(
        db.query('SELECT id FROM terminal_panes ORDER BY id;').map(
          (r) => r['id'],
        ),
        ['t0-p1', 't2-p1'],
        reason: 'the deleted tab must not leave its panes behind',
      );
    });

    test('a removed pane inside a surviving tab is really deleted', () {
      dao.saveWorkspace([splitTab('t0')], activeTabId: 't0');
      dao.saveWorkspace([tab('t0')], activeTabId: 't0', userClosed: true);

      expect(dao.loadWorkspace().tabs.single.panes.map((p) => p.id), ['t0-p1']);
      expect(db.query('SELECT id FROM terminal_panes;'), hasLength(1));
    });

    test('ordinals survive: reordering tabs reorders them on the way back', () {
      dao.saveWorkspace(workspace(4), activeTabId: 't0');
      dao.saveWorkspace([
        tab('t3'),
        tab('t0'),
        tab('t2'),
        tab('t1'),
      ], activeTabId: 't0');

      expect(dao.loadWorkspace().tabs.map((t) => t.id), [
        't3',
        't0',
        't2',
        't1',
      ]);
    });

    test('ordinals survive: closing a tab from the middle closes the gap', () {
      dao.saveWorkspace(workspace(4), activeTabId: 't0');
      dao.saveWorkspace([
        tab('t0'),
        tab('t2'),
        tab('t3'),
      ], activeTabId: 't0', userClosed: true);

      expect(dao.loadWorkspace().tabs.map((t) => t.id), ['t0', 't2', 't3']);
      expect(
        db.query('SELECT ordinal FROM terminal_tabs ORDER BY ordinal;').map(
          (r) => r['ordinal'],
        ),
        [0, 1, 2],
        reason: 'a hole in the ordinals is a workspace that restores wrong',
      );
    });

    test('pane ordinals survive a pane leaving the middle of a tab', () {
      final three = StoredTerminalTab(
        id: 't0',
        layout: PaneLayout.single('a')
            .split('a', SplitAxis.horizontal, 'b', 's1')
            .split('b', SplitAxis.vertical, 'c', 's2'),
        focusedPaneId: 'a',
        panes: [pane('t0', 'a'), pane('t0', 'b'), pane('t0', 'c')],
      );
      dao.saveWorkspace([three], activeTabId: 't0');

      dao.saveWorkspace([
        StoredTerminalTab(
          id: 't0',
          layout: PaneLayout.single('a').split('a', SplitAxis.vertical, 'c', 's2'),
          focusedPaneId: 'a',
          panes: [pane('t0', 'a'), pane('t0', 'c')],
        ),
      ], activeTabId: 't0', userClosed: true);

      expect(dao.loadWorkspace().tabs.single.panes.map((p) => p.id), [
        'a',
        'c',
      ]);
      expect(
        db
            .query('SELECT ordinal FROM terminal_panes ORDER BY ordinal;')
            .map((r) => r['ordinal']),
        [0, 1],
      );
    });

    test('a pane that moves between tabs moves, rather than being duplicated', () {
      dao.saveWorkspace([splitTab('t0')], activeTabId: 't0');

      // What detaching does: the pane keeps its id and gets a tab of its own.
      dao.saveWorkspace([
        tab('t0'),
        StoredTerminalTab(
          id: 'detached:t0-p2',
          layout: PaneLayout.single('t0-p2'),
          focusedPaneId: 't0-p2',
          detached: true,
          panes: [pane('detached:t0-p2', 't0-p2', scrollback: 'kept')],
        ),
      ], activeTabId: 't0', userClosed: true);

      final loaded = dao.loadWorkspace();
      expect(loaded.tabs.single.panes.map((p) => p.id), ['t0-p1']);
      expect(loaded.detached.single.panes.single.id, 't0-p2');
      expect(loaded.detached.single.panes.single.scrollback, 'kept');
      expect(db.query('SELECT id FROM terminal_panes;'), hasLength(2));
    });

    test('the whole workspace round-trips unchanged through save and load', () {
      const launch = AgentPaneLaunch(
        agentId: 'claude',
        executable: 'claude',
        arguments: ['--resume', 'ext-1'],
        workingDirectory: r'C:\ws',
        sessionId: 'sess-1',
      );
      final rich = [
        splitTab('t0'),
        StoredTerminalTab(
          id: 't1',
          layout: PaneLayout.single('t1-p1'),
          focusedPaneId: 't1-p1',
          panes: [
            StoredTerminalPane(
              id: 't1-p1',
              tabId: 't1',
              profileId: 'agent:claude',
              title: 'claude',
              workingDirectory: null,
              scrollback: 'agent output\r\n',
              agentLaunch: launch,
            ),
          ],
        ),
      ];

      // Reached incrementally, the way the app reaches it: a workspace, then
      // the change.
      dao.saveWorkspace([tab('t0')], activeTabId: 't0');
      dao.saveWorkspace(rich, activeTabId: 't1');

      final loaded = dao.loadWorkspace();
      expect(loaded.activeTabId, 't1');
      expect(loaded.tabs.map((t) => t.id), ['t0', 't1']);
      expect(loaded.tabs.first.layout.panes, ['t0-p1', 't0-p2']);
      expect(loaded.tabs.first.focusedPaneId, 't0-p2');
      final agentPane = loaded.tabs[1].panes.single;
      expect(agentPane.profileId, 'agent:claude');
      expect(agentPane.workingDirectory, isNull);
      expect(agentPane.scrollback, 'agent output\r\n');
      expect(agentPane.agentLaunch?.arguments, ['--resume', 'ext-1']);
    });

    test('a dao that never wrote this store still writes it correctly', () {
      // A second dao knows nothing about what the first one wrote, so it must
      // fall back to comparing against the store rather than trusting itself.
      dao.saveWorkspace(workspace(3), activeTabId: 't0');
      final fresh = TerminalWorkspaceDao(db);

      fresh.saveWorkspace([
        tab('t0'),
        splitTab('t1'),
      ], activeTabId: 't1', userClosed: true);

      final loaded = fresh.loadWorkspace();
      expect(loaded.tabs.map((t) => t.id), ['t0', 't1']);
      expect(loaded.tabs[1].panes.map((p) => p.id), ['t1-p1', 't1-p2']);
      expect(loaded.activeTabId, 't1');
    });

    test('a dao with no record of a pane writes its scrollback anyway', () {
      // The one thing compared from memory rather than from the store is the
      // scrollback text, so the fallback has to be "write it". A dao that has
      // never written this store has no record of anything.
      dao.saveWorkspace([tab('t0')], activeTabId: 't0');
      db.execute(
        "UPDATE terminal_panes SET scrollback = 'stale' WHERE id = 't0-p1';",
      );

      final fresh = TerminalWorkspaceDao(db);
      fresh.saveWorkspace([tab('t0')], activeTabId: 't0');

      expect(
        fresh.loadWorkspace().tabs.single.panes.single.scrollback,
        'some output',
      );
    });

    test('a structural save does not rewrite what the autosave just wrote', () {
      dao.saveWorkspace([tab('t0'), tab('t1')], activeTabId: 't0');
      dao.saveScrollback('t0-p1', 'newer output');
      db.reset();

      // The controller carries its cached encoding into the next structural
      // save, and that is exactly what the autosave already stored.
      dao.saveWorkspace([
        StoredTerminalTab(
          id: 't0',
          layout: PaneLayout.single('t0-p1'),
          focusedPaneId: 't0-p1',
          panes: [pane('t0', 't0-p1', scrollback: 'newer output')],
        ),
        tab('t1'),
      ], activeTabId: 't0');

      expect(db.workspaceWrites, 0);
      expect(
        dao.loadWorkspace().tabs.first.panes.single.scrollback,
        'newer output',
      );
    });

    test('clear forgets what was written, so the next save rewrites it', () {
      dao.saveWorkspace([tab('t0')], activeTabId: 't0');
      dao.clear();
      expect(dao.loadWorkspace().tabs, isEmpty);

      dao.saveWorkspace([tab('t0')], activeTabId: 't0');
      expect(
        dao.loadWorkspace().tabs.single.panes.single.scrollback,
        'some output',
      );
    });
  });

  group('the backup tables', () {
    late _CountingDatabase db;
    late TerminalWorkspaceDao dao;

    setUp(() {
      db = _CountingDatabase();
      dao = TerminalWorkspaceDao(db);
    });
    tearDown(() => db.close());

    test('cost nothing on a save that loses nothing', () {
      dao.saveWorkspace(workspace(10), activeTabId: 't0');
      db.reset();
      dao.saveWorkspace([...workspace(10), tab('t10')], activeTabId: 't0');

      expect(
        db.backupWrites,
        0,
        reason:
            'a backup is for a save that loses tabs; a growing save loses '
            'nothing',
      );
    });

    test('are still taken when a save empties a non-empty store', () {
      dao.saveWorkspace(workspace(3), activeTabId: 't0');
      db.reset();
      dao.saveWorkspace(const []);

      expect(db.backupWrites, greaterThan(0));
      expect(dao.loadBackup().tabs.map((t) => t.id), ['t0', 't1', 't2']);
      expect(dao.loadWorkspace().tabs, isEmpty);
    });

    test('are still taken when a save shrinks a workspace nobody closed', () {
      dao.saveWorkspace(workspace(3), activeTabId: 't0');
      dao.saveWorkspace([tab('t0')], activeTabId: 't0');

      expect(dao.loadBackup().tabs.map((t) => t.id), ['t0', 't1', 't2']);
    });
  });

  group('through the controller', () {
    /// Seeds [db] with a stored workspace of [tabs] tabs, then builds a
    /// controller over it — which restores them.
    ({
      _CountingDatabase db,
      ProviderContainer container,
      TerminalSessionsController controller,
    })
    restored(int tabs) {
      final db = _CountingDatabase();
      addTearDown(db.close);
      TerminalWorkspaceDao(db).saveWorkspace(workspace(tabs), activeTabId: 't0');

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(
        container.read(terminalSessionsControllerProvider).tabs,
        hasLength(tabs),
      );
      return (db: db, container: container, controller: controller);
    }

    final rowsWritten = <int, int>{};

    for (final n in scale) {
      test('opening a tab over $n restored tabs writes a fixed few rows', () {
        final (:db, :controller, container: _) = restored(n);
        db.reset();

        controller.openTab(TerminalProfile.powerShell);

        rowsWritten[n] = db.workspaceWrites;
        // The new tab, its pane, and the tab that stopped being the active one.
        expect(db.workspaceWrites, 3);
      });
    }

    test('and that cost does not grow with the workspace', () {
      expect(rowsWritten.keys, containsAll(scale));
      expect(
        rowsWritten.values.toSet(),
        hasLength(1),
        reason: 'writes per structural change: $rowsWritten',
      );
    });

    test('a save right after a restore writes nothing', () {
      // This is the shape of the report: the workspace came back exactly as it
      // was stored, so persisting it is not a change.
      final (:db, :controller, container: _) = restored(50);
      db.reset();

      controller.persistWorkspace();

      expect(db.workspaceWrites, 0);
    });

    test('the empty-workspace guard still refuses to write', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalWorkspaceDao(db);
      dao.saveWorkspace([
        StoredTerminalTab(
          id: 'tab-1',
          layout: PaneLayout.single('pane-1'),
          focusedPaneId: 'pane-1',
          panes: const [
            StoredTerminalPane(
              id: 'pane-1',
              tabId: 'tab-1',
              // Nothing in this build resolves it, so restore drops the pane
              // and, with it, the only tab.
              profileId: 'a-shell-this-build-no-longer-has',
              title: 'Something that was installed once',
              workingDirectory: null,
              scrollback: 'work the user has not finished',
            ),
          ],
        ),
      ], activeTabId: 'tab-1');

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);

      db.reset();
      controller.persistWorkspace();

      expect(db.workspaceWrites, 0);
      expect(dao.storedTabCount(), 1);
      expect(
        dao.loadWorkspace().tabs.single.panes.single.scrollback,
        'work the user has not finished',
      );
    });

    test('closing a tab writes only the delete it is', () {
      final (:db, :controller, :container) = restored(20);
      final tabs = container.read(terminalSessionsControllerProvider).tabs;
      db.reset();

      // Ending it rather than detaching: a detached session keeps its row.
      controller.closeTab(tabs.last.id, detach: false);

      expect(
        db.workspaceWrites,
        1,
        reason: 'one tab row deleted; its panes cascade',
      );
      expect(TerminalWorkspaceDao(db).loadWorkspace().tabs, hasLength(19));
    });
  });
}

/// An [AppDatabase] that records every statement the workspace dao issues.
///
/// Overriding [execute] rather than reaching for `sqlite3_changes` keeps the
/// unit honest: a statement the dao does not issue is a row it does not write,
/// and a statement it does issue writes exactly the one row its `WHERE id = ?`
/// or `ON CONFLICT (id)` names. `transaction` runs BEGIN/COMMIT on the raw
/// handle, so the counter never sees them.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> statements = [];

  void reset() => statements.clear();

  /// Writes against the live workspace tables.
  int get workspaceWrites => statements
      .where(
        (sql) =>
            !sql.contains('_backup') &&
            (sql.contains('terminal_tabs') || sql.contains('terminal_panes')),
      )
      .length;

  /// Writes against the backup mirrors, plus the metadata stamp that goes with
  /// them.
  int get backupWrites => statements
      .where((sql) => sql.contains('_backup') || sql.contains('app_metadata'))
      .length;

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements.add(sql);
    super.execute(sql, params);
  }
}
