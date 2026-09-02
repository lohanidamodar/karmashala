import 'dart:convert';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/data/terminal_layout_dao.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late TerminalLayoutDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = TerminalLayoutDao(db);
  });
  tearDown(() => db.close());

  StoredTerminalTab tab({String id = 'tab1'}) {
    final layout = PaneLayout.single(
      '$id-p1',
    ).split('$id-p1', SplitAxis.horizontal, '$id-p2', '$id-s1');
    return StoredTerminalTab(
      id: id,
      layout: layout,
      focusedPaneId: '$id-p2',
      panes: [
        StoredTerminalPane(
          id: '$id-p1',
          tabId: id,
          profileId: 'powershell',
          title: 'PowerShell',
          workingDirectory: r'C:\ws',
          scrollback: 'one',
        ),
        StoredTerminalPane(
          id: '$id-p2',
          tabId: id,
          profileId: 'cmd',
          title: 'Command Prompt',
          workingDirectory: null,
          scrollback: 'two',
        ),
      ],
    );
  }

  test('the schema reaches v7 with the terminal tables', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(7));
    final tables = db.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('terminal_tabs', 'terminal_panes');",
    );
    expect(tables.length, 2);
  });

  group('whether a pane was running (v26)', () {
    /// A one-pane tab, so the row's `was_live` is the only thing in question.
    StoredTerminalTab oneLive({required bool wasLive}) => StoredTerminalTab(
      id: 'tab1',
      layout: PaneLayout.single('p1'),
      focusedPaneId: 'p1',
      panes: [
        StoredTerminalPane(
          id: 'p1',
          tabId: 'tab1',
          profileId: 'powershell',
          title: 'PowerShell',
          workingDirectory: null,
          scrollback: 'output',
          wasLive: wasLive,
        ),
      ],
    );

    test('round-trips both ways', () {
      dao.saveLayout([oneLive(wasLive: true)], activeTabId: 'tab1');
      expect(dao.loadLayout().tabs.single.panes.single.wasLive, isTrue);

      // And back down again — a pane whose process ends must stop claiming to
      // be running, or the next launch would start what nobody left running.
      dao.saveLayout([oneLive(wasLive: false)], activeTabId: 'tab1');
      expect(dao.loadLayout().tabs.single.panes.single.wasLive, isFalse);
    });

    test('a row written before the column existed reads as not running', () {
      db.execute(
        'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
        'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
        [
          'old',
          0,
          jsonEncode(PaneLayout.single('p1').toJson()),
          'p1',
          1,
          '2026-01-01T00:00:00.000Z',
        ],
      );
      // Every column v26 did not add, exactly as an older build wrote them.
      db.execute(
        'INSERT INTO terminal_panes (id, tab_id, ordinal, profile_id, title, '
        'working_directory, scrollback, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
        [
          'p1',
          'old',
          0,
          'powershell',
          'PowerShell',
          null,
          'output',
          '2026-01-01T00:00:00.000Z',
        ],
      );
      expect(
        dao.loadLayout().tabs.single.panes.single.wasLive,
        isFalse,
        reason:
            'an upgrade must not spawn a shell per pane for rows that never '
            'claimed anything was running',
      );
    });

    test('the backup copy keeps it, so a recovery restores the same panes', () {
      dao.saveLayout([oneLive(wasLive: true)], activeTabId: 'tab1');
      // An empty save is what takes the copy.
      dao.saveLayout([], activeTabId: null);
      expect(dao.loadBackup().tabs.single.panes.single.wasLive, isTrue);
    });
  });

  test('saves and loads a workspace', () {
    dao.saveLayout([tab()], activeTabId: 'tab1');

    final loaded = dao.loadLayout();
    expect(loaded.activeTabId, 'tab1');
    expect(loaded.tabs.single.id, 'tab1');
    expect(loaded.tabs.single.focusedPaneId, 'tab1-p2');
    expect(loaded.tabs.single.layout.panes, ['tab1-p1', 'tab1-p2']);
    expect(loaded.tabs.single.panes.map((p) => p.scrollback), ['one', 'two']);
    expect(loaded.tabs.single.panes.first.workingDirectory, r'C:\ws');
    expect(loaded.tabs.single.panes.first.profileId, 'powershell');
    expect(loaded.tabs.single.panes[1].workingDirectory, isNull);
    expect(loaded.tabs.single.panes[1].title, 'Command Prompt');
  });

  test('an empty database loads an empty workspace', () {
    final loaded = dao.loadLayout();
    expect(loaded.tabs, isEmpty);
    expect(loaded.activeTabId, isNull);
  });

  test('saving replaces the previous workspace rather than appending', () {
    dao.saveLayout([tab()], activeTabId: 'tab1');
    dao.saveLayout([tab(id: 'tab2')], activeTabId: 'tab2');
    final loaded = dao.loadLayout();
    expect(loaded.tabs.map((t) => t.id), ['tab2']);
    expect(loaded.activeTabId, 'tab2');
  });

  test('saveScrollback updates one pane in place', () {
    dao.saveLayout([tab()], activeTabId: 'tab1');
    dao.saveScrollback('tab1-p1', 'updated');
    final panes = dao.loadLayout().tabs.single.panes;
    expect(panes.first.scrollback, 'updated');
    expect(panes[1].scrollback, 'two', reason: 'the other pane is untouched');
  });

  test('saveScrollback for an unknown pane is a no-op', () {
    dao.saveLayout([tab()], activeTabId: 'tab1');
    dao.saveScrollback('ghost', 'nothing');
    expect(dao.loadLayout().tabs.single.panes.length, 2);
  });

  test('clear removes tabs and cascades to their panes', () {
    dao.saveLayout([tab()], activeTabId: 'tab1');
    dao.clear();
    expect(db.query('SELECT id FROM terminal_panes;'), isEmpty);
    expect(dao.loadLayout().tabs, isEmpty);
  });

  test('a tab with unparseable layout json is skipped, not thrown on', () {
    db.execute(
      'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
      'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['bad', 0, '{not json', null, 1, '2026-01-01T00:00:00.000Z'],
    );
    expect(dao.loadLayout().tabs, isEmpty);
  });

  test('a tab whose layout is valid json but not a layout is skipped', () {
    db.execute(
      'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
      'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['bad', 0, '{"t":"split"}', null, 1, '2026-01-01T00:00:00.000Z'],
    );
    expect(dao.loadLayout().tabs, isEmpty);
  });

  test('tabs and panes come back in the order they were saved', () {
    dao.saveLayout([
      tab(id: 'a'),
      tab(id: 'b'),
      tab(id: 'c'),
    ], activeTabId: 'b');
    final loaded = dao.loadLayout();
    expect(loaded.tabs.map((t) => t.id), ['a', 'b', 'c']);
    expect(loaded.tabs.first.panes.map((p) => p.id), ['a-p1', 'a-p2']);
  });

  test('an active tab id that no longer exists comes back as null', () {
    dao.saveLayout([tab()], activeTabId: 'gone');
    expect(dao.loadLayout().activeTabId, isNull);
  });
}
