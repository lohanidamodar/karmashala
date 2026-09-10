import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_layout_dao.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fake_instance.dart';

/// What a **structural** save costs the database, counted rather than timed.
///
/// The owner's report against 1.1.5 was "resuming session still makes ui
/// laggy". Resume itself had already stopped rebuilding the pane it resumes
/// into (`resume_cost_test.dart`), so the remaining cost was the save that
/// immediately follows: `saveLayout` was a destructive full replace —
/// `DELETE FROM terminal_tabs;` and then one INSERT per tab and per pane,
/// each pane carrying its whole scrollback — run on *every* structural change,
/// through synchronous `package:sqlite3` bindings, on the UI isolate.
/// `tool/benchmark/terminal_scale_bench.dart` measured 645 ms at the 100-pane
/// scale target.
///
/// Resuming a session adds one pane to one tab. These tests pin the rule that
/// makes that cost what it says: **a save writes the rows that changed**, and
/// nothing else — so the write cost of one structural change is flat in the
/// size of the layout, in the shape `scale_curve_test.dart` established.
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
    bool wasLive = false,
  }) => StoredTerminalPane(
    id: paneId,
    tabId: tabId,
    profileId: 'powershell',
    title: 'PowerShell',
    workingDirectory: r'C:\ws',
    scrollback: scrollback,
    wasLive: wasLive,
  );

  /// A one-pane tab, the ordinary shape of a restored layout.
  StoredTerminalTab tab(String id, {bool wasLive = false}) => StoredTerminalTab(
    id: id,
    layout: PaneLayout.single('$id-p1'),
    focusedPaneId: '$id-p1',
    panes: [pane(id, '$id-p1', wasLive: wasLive)],
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

  List<StoredTerminalTab> storedLayout(int tabs) => [
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
        final dao = TerminalLayoutDao(db);

        final tabs = storedLayout(n);
        dao.saveLayout(tabs, activeTabId: 't0');

        // One tab gains a pane. Everything else is byte-for-byte what was
        // already stored.
        final grown = [...tabs]..[n - 1] = splitTab('t${n - 1}');
        db.reset();
        dao.saveLayout(grown, activeTabId: 't0');

        rowsWritten[n] = db.layoutWrites;
        expect(
          db.layoutWrites,
          2,
          reason:
              'the tab whose layout changed, and the pane that appeared — '
              'nothing else moved',
        );
        // The store still says exactly what it was asked to.
        expect(
          dao.loadLayout().tabs.last.panes.map((p) => p.id),
          ['t${n - 1}-p1', 't${n - 1}-p2'],
        );
      });
    }

    test('is flat: a hundred tabs cost what one tab costs', () {
      expect(rowsWritten.keys, containsAll(scale));
      expect(
        rowsWritten.values.toSet(),
        hasLength(1),
        reason: 'row writes must not grow with the layout: $rowsWritten',
      );
    });
  });

  group('the scrollback column', () {
    test('is left alone when only the cheap columns moved', () {
      // The first structural save of **every** run is this shape. A pane that
      // was running when the app closed comes back restored, so `was_live`
      // flips 1 -> 0 for every one of them at once — and the whole row used to
      // be rewritten to record it, carrying up to
      // `kDurableScrollbackMaxBytes` of text per pane. Measured on four
      // restored agent panes at the durable cap: 1 MB written for four
      // booleans, ~2.8 ms of the ~10 ms a Start press cost.
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);
      dao.saveLayout([
        tab('t0', wasLive: true),
        tab('t1', wasLive: true),
      ], activeTabId: 't0');
      db.reset();

      dao.saveLayout([tab('t0'), tab('t1')], activeTabId: 't0');

      expect(
        db.layoutWrites,
        2,
        reason: 'one statement per pane whose was_live moved, and no more',
      );
      expect(
        db.scrollbackWrites,
        0,
        reason:
            'nothing about the text changed, so the expensive column must not '
            'be part of the statement that records a boolean',
      );
      // The record is still correct in both directions.
      final loaded = dao.loadLayout();
      expect(loaded.tabs.map((t) => t.panes.single.wasLive), [false, false]);
      expect(
        loaded.tabs.map((t) => t.panes.single.scrollback),
        ['some output', 'some output'],
      );
    });

    test('is written when the text itself moved, metadata or not', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);
      dao.saveLayout([tab('t0', wasLive: true)], activeTabId: 't0');
      db.reset();

      dao.saveLayout([
        StoredTerminalTab(
          id: 't0',
          layout: PaneLayout.single('t0-p1'),
          focusedPaneId: 't0-p1',
          panes: [pane('t0', 't0-p1', scrollback: 'more output')],
        ),
      ], activeTabId: 't0');

      expect(db.scrollbackWrites, 1);
      expect(dao.loadLayout().tabs.single.panes.single.scrollback, 'more output');
      expect(dao.loadLayout().tabs.single.panes.single.wasLive, isFalse);
    });

    test('a pane the store has never seen is written in full', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);

      dao.saveLayout([tab('t0')], activeTabId: 't0');

      expect(db.scrollbackWrites, 1);
      expect(dao.loadLayout().tabs.single.panes.single.scrollback, 'some output');
    });
  });

  group('a save that changes nothing', () {
    test('writes nothing at all', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);
      final tabs = storedLayout(10);
      dao.saveLayout(tabs, activeTabId: 't0');

      db.reset();
      dao.saveLayout(tabs, activeTabId: 't0');
      dao.saveLayout(tabs, activeTabId: 't0');

      expect(db.layoutWrites, 0);
    });

    test('is still a save: the store is unchanged, not emptied', () {
      final db = _CountingDatabase();
      addTearDown(db.close);
      final dao = TerminalLayoutDao(db);
      dao.saveLayout(storedLayout(3), activeTabId: 't1');
      dao.saveLayout(storedLayout(3), activeTabId: 't1');

      final loaded = dao.loadLayout();
      expect(loaded.tabs.map((t) => t.id), ['t0', 't1', 't2']);
      expect(loaded.activeTabId, 't1');
      expect(loaded.tabs.first.panes.single.scrollback, 'some output');
    });
  });

  group('what a full replace got for free', () {
    late _CountingDatabase db;
    late TerminalLayoutDao dao;

    setUp(() {
      db = _CountingDatabase();
      dao = TerminalLayoutDao(db);
    });
    tearDown(() => db.close());

    test('a removed tab is really deleted, and its panes with it', () {
      dao.saveLayout(storedLayout(3), activeTabId: 't0');
      final kept = [tab('t0'), tab('t2')];

      dao.saveLayout(kept, activeTabId: 't0', userClosed: true);

      expect(dao.loadLayout().tabs.map((t) => t.id), ['t0', 't2']);
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
      dao.saveLayout([splitTab('t0')], activeTabId: 't0');
      dao.saveLayout([tab('t0')], activeTabId: 't0', userClosed: true);

      expect(dao.loadLayout().tabs.single.panes.map((p) => p.id), ['t0-p1']);
      expect(db.query('SELECT id FROM terminal_panes;'), hasLength(1));
    });

    test('ordinals survive: reordering tabs reorders them on the way back', () {
      dao.saveLayout(storedLayout(4), activeTabId: 't0');
      dao.saveLayout([
        tab('t3'),
        tab('t0'),
        tab('t2'),
        tab('t1'),
      ], activeTabId: 't0');

      expect(dao.loadLayout().tabs.map((t) => t.id), [
        't3',
        't0',
        't2',
        't1',
      ]);
    });

    test('ordinals survive: closing a tab from the middle closes the gap', () {
      dao.saveLayout(storedLayout(4), activeTabId: 't0');
      dao.saveLayout([
        tab('t0'),
        tab('t2'),
        tab('t3'),
      ], activeTabId: 't0', userClosed: true);

      expect(dao.loadLayout().tabs.map((t) => t.id), ['t0', 't2', 't3']);
      expect(
        db.query('SELECT ordinal FROM terminal_tabs ORDER BY ordinal;').map(
          (r) => r['ordinal'],
        ),
        [0, 1, 2],
        reason: 'a hole in the ordinals is a layout that restores wrong',
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
      dao.saveLayout([three], activeTabId: 't0');

      dao.saveLayout([
        StoredTerminalTab(
          id: 't0',
          layout: PaneLayout.single('a').split('a', SplitAxis.vertical, 'c', 's2'),
          focusedPaneId: 'a',
          panes: [pane('t0', 'a'), pane('t0', 'c')],
        ),
      ], activeTabId: 't0', userClosed: true);

      expect(dao.loadLayout().tabs.single.panes.map((p) => p.id), [
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
      dao.saveLayout([splitTab('t0')], activeTabId: 't0');

      // What detaching does: the pane keeps its id and gets a tab of its own.
      dao.saveLayout([
        tab('t0'),
        StoredTerminalTab(
          id: 'detached:t0-p2',
          layout: PaneLayout.single('t0-p2'),
          focusedPaneId: 't0-p2',
          detached: true,
          panes: [pane('detached:t0-p2', 't0-p2', scrollback: 'kept')],
        ),
      ], activeTabId: 't0', userClosed: true);

      final loaded = dao.loadLayout();
      expect(loaded.tabs.single.panes.map((p) => p.id), ['t0-p1']);
      expect(loaded.detached.single.panes.single.id, 't0-p2');
      expect(loaded.detached.single.panes.single.scrollback, 'kept');
      expect(db.query('SELECT id FROM terminal_panes;'), hasLength(2));
    });

    test('the whole layout round-trips unchanged through save and load', () {
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

      // Reached incrementally, the way the app reaches it: a layout, then
      // the change.
      dao.saveLayout([tab('t0')], activeTabId: 't0');
      dao.saveLayout(rich, activeTabId: 't1');

      final loaded = dao.loadLayout();
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
      dao.saveLayout(storedLayout(3), activeTabId: 't0');
      final fresh = TerminalLayoutDao(db);

      fresh.saveLayout([
        tab('t0'),
        splitTab('t1'),
      ], activeTabId: 't1', userClosed: true);

      final loaded = fresh.loadLayout();
      expect(loaded.tabs.map((t) => t.id), ['t0', 't1']);
      expect(loaded.tabs[1].panes.map((p) => p.id), ['t1-p1', 't1-p2']);
      expect(loaded.activeTabId, 't1');
    });

    test('a dao with no record of a pane writes its scrollback anyway', () {
      // The one thing compared from memory rather than from the store is the
      // scrollback text, so the fallback has to be "write it". A dao that has
      // never written this store has no record of anything.
      dao.saveLayout([tab('t0')], activeTabId: 't0');
      db.execute(
        "UPDATE terminal_panes SET scrollback = 'stale' WHERE id = 't0-p1';",
      );

      final fresh = TerminalLayoutDao(db);
      fresh.saveLayout([tab('t0')], activeTabId: 't0');

      expect(
        fresh.loadLayout().tabs.single.panes.single.scrollback,
        'some output',
      );
    });

    test('a structural save does not rewrite what the autosave just wrote', () {
      dao.saveLayout([tab('t0'), tab('t1')], activeTabId: 't0');
      dao.saveScrollback('t0-p1', 'newer output');
      db.reset();

      // The controller carries its cached encoding into the next structural
      // save, and that is exactly what the autosave already stored.
      dao.saveLayout([
        StoredTerminalTab(
          id: 't0',
          layout: PaneLayout.single('t0-p1'),
          focusedPaneId: 't0-p1',
          panes: [pane('t0', 't0-p1', scrollback: 'newer output')],
        ),
        tab('t1'),
      ], activeTabId: 't0');

      expect(db.layoutWrites, 0);
      expect(
        dao.loadLayout().tabs.first.panes.single.scrollback,
        'newer output',
      );
    });

    test('clear forgets what was written, so the next save rewrites it', () {
      dao.saveLayout([tab('t0')], activeTabId: 't0');
      dao.clear();
      expect(dao.loadLayout().tabs, isEmpty);

      dao.saveLayout([tab('t0')], activeTabId: 't0');
      expect(
        dao.loadLayout().tabs.single.panes.single.scrollback,
        'some output',
      );
    });
  });

  group('the backup tables', () {
    late _CountingDatabase db;
    late TerminalLayoutDao dao;

    setUp(() {
      db = _CountingDatabase();
      dao = TerminalLayoutDao(db);
    });
    tearDown(() => db.close());

    test('cost nothing on a save that loses nothing', () {
      dao.saveLayout(storedLayout(10), activeTabId: 't0');
      db.reset();
      dao.saveLayout([...storedLayout(10), tab('t10')], activeTabId: 't0');

      expect(
        db.backupWrites,
        0,
        reason:
            'a backup is for a save that loses tabs; a growing save loses '
            'nothing',
      );
    });

    test('are still taken when a save empties a non-empty store', () {
      dao.saveLayout(storedLayout(3), activeTabId: 't0');
      db.reset();
      dao.saveLayout(const []);

      expect(db.backupWrites, greaterThan(0));
      expect(dao.loadBackup().tabs.map((t) => t.id), ['t0', 't1', 't2']);
      expect(dao.loadLayout().tabs, isEmpty);
    });

    test('are still taken when a save shrinks a layout nobody closed', () {
      dao.saveLayout(storedLayout(3), activeTabId: 't0');
      dao.saveLayout([tab('t0')], activeTabId: 't0');

      expect(dao.loadBackup().tabs.map((t) => t.id), ['t0', 't1', 't2']);
    });
  });

  group('through the controller', () {
    /// Seeds [db] with a stored layout of [tabs] tabs, then builds a
    /// controller over it — which restores them.
    ({
      _CountingDatabase db,
      ProviderContainer container,
      TerminalSessionsController controller,
    })
    restored(int tabs) {
      final db = _CountingDatabase();
      addTearDown(db.close);
      TerminalLayoutDao(db).saveLayout(storedLayout(tabs), activeTabId: 't0');

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

        rowsWritten[n] = db.layoutWrites;
        // The new tab, its pane, and the tab that stopped being the active one.
        expect(db.layoutWrites, 3);
      });
    }

    test('and that cost does not grow with the layout', () {
      expect(rowsWritten.keys, containsAll(scale));
      expect(
        rowsWritten.values.toSet(),
        hasLength(1),
        reason: 'writes per structural change: $rowsWritten',
      );
    });

    test('a save right after a restore writes nothing', () {
      // This is the shape of the report: the layout came back exactly as it
      // was stored, so persisting it is not a change.
      final (:db, :controller, container: _) = restored(50);
      db.reset();

      controller.persistLayout();

      expect(db.layoutWrites, 0);
    });

    test('the empty-layout guard still refuses to write', () {
      final db = _CountingDatabase();
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
      controller.persistLayout();

      expect(db.layoutWrites, 0);
      expect(dao.storedTabCount(), 1);
      expect(
        dao.loadLayout().tabs.single.panes.single.scrollback,
        'work the user has not finished',
      );
    });

    test('the first save of a run rewrites no pane it merely read back', () {
      // The shape of the report, end to end. Every pane that was running when
      // the app closed comes back **restored**, so the first structural save
      // of the run has `was_live` moving on all of them at once — and that
      // save used to carry every pane's whole scrollback with it.
      final db = _CountingDatabase();
      addTearDown(db.close);
      TerminalLayoutDao(db).saveLayout([
        for (var i = 0; i < 20; i++) tab('t$i', wasLive: true),
      ], activeTabId: 't0');

      final container = fakeTerminalContainer(
        database: db,
        // So every pane comes back dormant, including the active tab's:
        // what is being counted here is the metadata flip, not the restart.
        restoreLivePanes: false,
      );
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      db.reset();

      controller.persistStructure();

      expect(
        db.layoutWrites,
        20,
        reason: 'one statement per pane that stopped being live',
      );
      expect(
        db.scrollbackWrites,
        0,
        reason:
            'not one of these panes has output the store has not already got',
      );
    });

    test('a pane restarted at launch is not encoded back out again', () {
      // The active tab's panes come back **running**, replaying their stored
      // scrollback into a live buffer. The controller's encoding cache used to
      // know nothing about them, so the first structural save of the run
      // encoded each one in full — the whole durable window, on the UI
      // isolate — only to rediscover the text the restore had just read out.
      final db = _CountingDatabase();
      addTearDown(db.close);
      TerminalLayoutDao(db).saveLayout([
        tab('t0', wasLive: true),
        tab('t1', wasLive: true),
      ], activeTabId: 't0');

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      db.reset();

      controller.persistStructure();

      expect(
        db.scrollbackWrites,
        0,
        reason: 'the store already holds every line either pane came back with',
      );
      // Deferred, not dropped: the restarted pane's buffer will move past what
      // the store has, so it still owes a write and the autosave still makes
      // it.
      expect(controller.hasDirtyScrollback, isTrue);
      controller.saveDirtyScrollback(budget: const Duration(minutes: 1));
      expect(
        TerminalLayoutDao(db).loadLayout().tabs.first.panes.single.scrollback,
        contains('some output'),
      );
    });

    test('resuming a restored session writes no history back', () {
      // The Start press itself. The pane hands its buffer to the pane that
      // replaces it, and the save that follows must not encode that buffer to
      // find out it is holding the history the store already stored.
      const launch = AgentPaneLaunch(
        agentId: 'claude',
        executable: 'claude',
        workingDirectory: r'C:\ws',
        sessionId: 'sess-1',
      );
      final db = _CountingDatabase();
      addTearDown(db.close);
      TerminalLayoutDao(db).saveLayout([
        StoredTerminalTab(
          id: 't0',
          layout: PaneLayout.single('t0-p1'),
          focusedPaneId: 't0-p1',
          panes: [
            StoredTerminalPane(
              id: 't0-p1',
              tabId: 't0',
              profileId: 'agent:claude',
              title: 'claude',
              workingDirectory: r'C:\ws',
              scrollback: 'a conversation the user wants back\r\n',
              agentLaunch: launch,
              wasLive: true,
            ),
          ],
        ),
      ], activeTabId: 't0');

      final container = fakeTerminalContainer(database: db);
      addTearDown(container.dispose);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      // What the workbench does when it draws the pane, and what makes the
      // buffer adoptable.
      controller.instanceFor('t0-p1')!.terminal;
      db.reset();

      controller.startAgentInPane(
        't0-p1',
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          arguments: ['--resume', 'ext-1'],
          workingDirectory: r'C:\ws',
          sessionId: 'sess-1',
        ),
      );

      expect(
        db.scrollbackWrites,
        0,
        reason: 'the resumed pane is holding the buffer it was already showing',
      );
      expect(db.layoutWrites, 1, reason: 'the pane row, for its new command');
      expect(controller.hasDirtyScrollback, isTrue);
      controller.saveDirtyScrollback(budget: const Duration(minutes: 1));
      expect(
        TerminalLayoutDao(db).loadLayout().tabs.single.panes.single.scrollback,
        contains('a conversation the user wants back'),
      );
    });

    test('closing a tab writes only the delete it is', () {
      final (:db, :controller, :container) = restored(20);
      final tabs = container.read(terminalSessionsControllerProvider).tabs;
      db.reset();

      // Ending it rather than detaching: a detached session keeps its row.
      controller.closeTab(tabs.last.id, detach: false);

      expect(
        db.layoutWrites,
        1,
        reason: 'one tab row deleted; its panes cascade',
      );
      expect(TerminalLayoutDao(db).loadLayout().tabs, hasLength(19));
    });
  });
}

/// An [AppDatabase] that records every statement the layout dao issues.
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

  /// Writes against the live layout tables.
  int get layoutWrites => statements
      .where(
        (sql) =>
            !sql.contains('_backup') &&
            (sql.contains('terminal_tabs') || sql.contains('terminal_panes')),
      )
      .length;

  /// Writes that carry a pane's scrollback text. The expensive column, and the
  /// one a structural save is meant to touch only when the text moved — a
  /// statement that does not name it cannot have written it.
  int get scrollbackWrites => statements
      .where((sql) => !sql.contains('_backup') && sql.contains('scrollback'))
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
