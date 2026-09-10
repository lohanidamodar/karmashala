import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/pane_layout.dart';
import '../domain/workspace_layout.dart';

/// One persisted terminal pane: how to relaunch it, and what was on its screen.
class StoredTerminalPane {
  const StoredTerminalPane({
    required this.id,
    required this.tabId,
    required this.profileId,
    required this.title,
    required this.workingDirectory,
    required this.scrollback,
    this.agentLaunch,
    this.wasLive = false,
  });

  final String id;
  final String tabId;
  final String profileId;
  final String title;
  final String? workingDirectory;
  final String scrollback;

  /// The agent CLI this pane ran, when it ran one. A shell pane stores `null`.
  final AgentPaneLaunch? agentLaunch;

  /// Whether a process was running behind this pane when the row was written —
  /// a record of the pane's shape cannot tell a live shell from a buffer full
  /// of last week. Refreshed by every structural save and by the save on quit,
  /// and false by default, so a row written before the column reads as "not
  /// recorded".
  final bool wasLive;
}

/// One persisted tab: its pane tree plus the panes the tree references.
///
/// A **detached** session — one whose tab the user closed while it kept
/// running — is stored the same way, as a single-pane row with [detached] set;
/// sharing the table is what preserves its scrollback by the same code path.
class StoredTerminalTab {
  const StoredTerminalTab({
    required this.id,
    required this.layout,
    required this.focusedPaneId,
    required this.panes,
    this.detached = false,
  });

  final String id;
  final PaneLayout layout;
  final String? focusedPaneId;
  final List<StoredTerminalPane> panes;
  final bool detached;
}

/// Everything needed to bring the terminal back as the user left it.
class StoredTerminalLayout {
  const StoredTerminalLayout({
    required this.tabs,
    required this.activeTabId,
    this.detached = const [],
  });

  static const empty = StoredTerminalLayout(tabs: [], activeTabId: null);

  final List<StoredTerminalTab> tabs;

  /// Sessions that had no tab when the app last exited, in the order they were
  /// detached.
  final List<StoredTerminalTab> detached;

  final String? activeTabId;
}

/// The `app_metadata` key stamped when a save emptied a non-empty layout: when
/// the copy was taken, which the backup rows' own `updated_at` does not say.
/// The key still says "workspace" because renaming it would orphan the
/// timestamp already on disk.
const kTerminalLayoutBackupAtKey = 'terminal.workspace_backup_at';

/// The `app_metadata` key holding the grid the app last drew a terminal pane
/// at.
///
/// Carried over from the last run because a restored layout's panes parse their
/// stored scrollback during `build`, before any layout pass could tell them how
/// wide a pane is. See `TerminalGridHint`.
const kTerminalPaneGridKey = 'terminal.pane_grid';

/// The `app_metadata` key holding the workspace split tree — see
/// [WorkspaceLayout]. One row about all the tabs, because the tree is a
/// document, and half of one written across N rows cannot be read back.
const kTerminalWorkspaceKey = 'terminal.workspace_tree';

/// Reads and writes the terminal layout (schema v7, backup tables v11) with
/// hand-written SQL. Loading is deliberately forgiving: an unparseable row is
/// skipped, because a corrupt layout must never make the terminal unopenable.
class TerminalLayoutDao {
  TerminalLayoutDao(this._db);

  final AppDatabase _db;

  /// The scrollback text this dao last saw in the store, by pane id.
  ///
  /// Everything else a save compares it reads back from the store; scrollback
  /// is the one column too expensive to re-read, so the dao keeps its own
  /// record and writes whenever it has none.
  final Map<String, String> _writtenScrollback = {};

  /// How many tabs (including detached rows) the store holds — the cheapest
  /// form of "would an empty save destroy something?", reading no scrollback.
  int storedTabCount() {
    final rows = _db.query('SELECT COUNT(*) AS n FROM terminal_tabs;');
    if (rows.isEmpty) return 0;
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Makes the stored layout be [tabs], by writing **only the rows that differ
  /// from what is stored**: a full `DELETE` plus an INSERT per row rewrote every
  /// pane's scrollback on every structural change, measured at 645 ms of
  /// synchronous work on the frame that resumes a hundred-pane session.
  ///
  /// A copy of the outgoing layout is taken first, inside the same transaction,
  /// when this save loses something — it empties a store that was not empty, or
  /// stores fewer tabs while [userClosed] is false.
  void saveLayout(
    List<StoredTerminalTab> tabs, {
    String? activeTabId,
    bool userClosed = false,
  }) {
    final now = isoFromDate(DateTime.now());
    final written = _db.transaction(() {
      final stored = storedTabCount();
      if (tabs.isEmpty || (!userClosed && tabs.length < stored)) {
        _backupLayout(now, stored);
      }
      return _writeChangedRows(tabs, activeTabId, now);
    });
    // Adopted only once the transaction has committed: a record claiming rows
    // that were rolled back is the one way this dao could skip a write it owed.
    _writtenScrollback
      ..clear()
      ..addAll(written);
  }

  /// The body of [saveLayout]: upsert what moved, delete what vanished, and
  /// return what [_writtenScrollback] should become once the transaction has
  /// committed.
  ///
  /// Upserts first, deletes after — a pane that moved out of a tab that is
  /// itself going has to be re-parented before the foreign key cascade takes it.
  /// `ON CONFLICT DO UPDATE` rather than `INSERT OR REPLACE`, because REPLACE
  /// deletes the conflicting row first and would cascade a tab's panes away.
  Map<String, String> _writeChangedRows(
    List<StoredTerminalTab> tabs,
    String? activeTabId,
    String now,
  ) {
    final storedTabs = {
      for (final row in _db.query(
        'SELECT id, ordinal, layout, focused_pane_id, is_active, detached '
        'FROM terminal_tabs;',
      ))
        row['id']! as String: row,
    };
    final storedPanes = {
      for (final row in _db.query(
        'SELECT id, tab_id, ordinal, profile_id, title, working_directory, '
        'launch_command, was_live FROM terminal_panes;',
      ))
        row['id']! as String: row,
    };

    final liveTabs = <String>{};
    final livePanes = <String>{};
    final written = <String, String>{};

    for (var i = 0; i < tabs.length; i++) {
      final tab = tabs[i];
      liveTabs.add(tab.id);
      final layout = jsonEncode(tab.layout.toJson());
      final isActive = intFromBool(!tab.detached && tab.id == activeTabId);
      final detached = intFromBool(tab.detached);
      final storedTab = storedTabs[tab.id];
      if (storedTab == null ||
          storedTab['ordinal'] != i ||
          storedTab['layout'] != layout ||
          storedTab['focused_pane_id'] != tab.focusedPaneId ||
          storedTab['is_active'] != isActive ||
          storedTab['detached'] != detached) {
        _db.execute(
          'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
          'is_active, detached, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT (id) DO UPDATE SET ordinal = excluded.ordinal, '
          'layout = excluded.layout, '
          'focused_pane_id = excluded.focused_pane_id, '
          'is_active = excluded.is_active, detached = excluded.detached, '
          'updated_at = excluded.updated_at;',
          [tab.id, i, layout, tab.focusedPaneId, isActive, detached, now],
        );
      }

      for (var j = 0; j < tab.panes.length; j++) {
        final pane = tab.panes[j];
        livePanes.add(pane.id);
        final launch = pane.agentLaunch == null
            ? null
            : jsonEncode(pane.agentLaunch!.toJson());
        final wasLive = intFromBool(pane.wasLive);
        final storedPane = storedPanes[pane.id];
        // The scrollback column is asked about **separately** from the other
        // eight because it is the only expensive one. Written together, any
        // column moving rewrote the text — and the first structural save of
        // every run flips `was_live` 1 -> 0 for every restored pane at once,
        // measured as 1 MB rewritten to record four booleans.
        final scrollbackChanged =
            storedPane == null || _scrollbackChanged(pane);
        final metadataChanged =
            storedPane == null ||
            storedPane['tab_id'] != tab.id ||
            storedPane['ordinal'] != j ||
            storedPane['profile_id'] != pane.profileId ||
            storedPane['title'] != pane.title ||
            storedPane['working_directory'] != pane.workingDirectory ||
            storedPane['launch_command'] != launch ||
            storedPane['was_live'] != wasLive;
        if (scrollbackChanged) {
          _db.execute(
            'INSERT INTO terminal_panes (id, tab_id, ordinal, profile_id, '
            'title, working_directory, scrollback, launch_command, was_live, '
            'updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (id) DO UPDATE SET tab_id = excluded.tab_id, '
            'ordinal = excluded.ordinal, profile_id = excluded.profile_id, '
            'title = excluded.title, '
            'working_directory = excluded.working_directory, '
            'scrollback = excluded.scrollback, '
            'launch_command = excluded.launch_command, '
            'was_live = excluded.was_live, '
            'updated_at = excluded.updated_at;',
            [
              pane.id,
              tab.id,
              j,
              pane.profileId,
              pane.title,
              pane.workingDirectory,
              pane.scrollback,
              launch,
              wasLive,
              now,
            ],
          );
          written[pane.id] = pane.scrollback;
        } else {
          // The store already holds this pane's text, so only the cheap
          // columns are written. The row certainly exists — [_scrollbackChanged]
          // answers "changed" for a pane this dao has no record of.
          if (metadataChanged) {
            _db.execute(
              'UPDATE terminal_panes SET tab_id = ?, ordinal = ?, '
              'profile_id = ?, title = ?, working_directory = ?, '
              'launch_command = ?, was_live = ?, updated_at = ? WHERE id = ?;',
              [
                tab.id,
                j,
                pane.profileId,
                pane.title,
                pane.workingDirectory,
                launch,
                wasLive,
                now,
                pane.id,
              ],
            );
          }
          // Nothing was written to the text column either way, so the record
          // carries over.
          written[pane.id] = _writtenScrollback[pane.id]!;
        }
      }
    }

    for (final entry in storedPanes.entries) {
      if (livePanes.contains(entry.key)) continue;
      final tabId = entry.value['tab_id'] as String?;
      // A pane whose tab is going too needs no statement of its own — the
      // foreign key cascades — which keeps closing a tab one write.
      final tabGoing =
          tabId != null &&
          storedTabs.containsKey(tabId) &&
          !liveTabs.contains(tabId);
      if (tabGoing) continue;
      _db.execute('DELETE FROM terminal_panes WHERE id = ?;', [entry.key]);
    }
    for (final id in storedTabs.keys) {
      if (liveTabs.contains(id)) continue;
      _db.execute('DELETE FROM terminal_tabs WHERE id = ?;', [id]);
    }
    return written;
  }

  /// Whether [pane]'s scrollback differs from what this dao last wrote for it.
  /// "No record" counts as changed: the dao only ever skips a write it can
  /// account for.
  bool _scrollbackChanged(StoredTerminalPane pane) {
    final written = _writtenScrollback[pane.id];
    if (written == null) return true;
    // The controller hands back the *same* string instance for a pane whose
    // buffer has not moved, so the common case settles on a pointer compare.
    return !identical(written, pane.scrollback) && written != pane.scrollback;
  }

  /// Updates one pane's scrollback in place — the autosave path, which must not
  /// rewrite the whole layout every tick.
  void saveScrollback(String paneId, String scrollback) {
    _db.execute(
      'UPDATE terminal_panes SET scrollback = ?, updated_at = ? WHERE id = ?;',
      [scrollback, isoFromDate(DateTime.now()), paneId],
    );
    // Only for a pane the dao already knows the store holds: an UPDATE that
    // matched no row must not leave a record claiming it did.
    if (_writtenScrollback.containsKey(paneId)) {
      _writtenScrollback[paneId] = scrollback;
    }
  }

  /// Copies the stored layout into the backup tables, replacing whatever was
  /// there. Does nothing when there is nothing to lose.
  ///
  /// Called from inside [saveLayout]'s transaction, so a failure anywhere in
  /// the save rolls the copy back with it. [stored] is the tab count
  /// [saveLayout] has already taken.
  ///
  /// **The largest single synchronous unit of database work in the app, and it
  /// is left as it is**: the `INSERT ... SELECT` copies every stored pane's
  /// scrollback on the UI isolate — 7.8 MB over 100 panes holding 64 KiB each —
  /// and fires only when a save would otherwise lose something.
  void _backupLayout(String now, int stored) {
    if (stored == 0) return;
    _db.execute('DELETE FROM terminal_panes_backup;');
    _db.execute('DELETE FROM terminal_tabs_backup;');
    _db.execute(
      'INSERT INTO terminal_tabs_backup (id, ordinal, layout, focused_pane_id, '
      'is_active, detached, updated_at) SELECT id, ordinal, layout, '
      'focused_pane_id, is_active, detached, updated_at FROM terminal_tabs;',
    );
    _db.execute(
      'INSERT INTO terminal_panes_backup (id, tab_id, ordinal, profile_id, '
      'title, working_directory, scrollback, launch_command, was_live, '
      'updated_at) '
      'SELECT id, tab_id, ordinal, profile_id, title, working_directory, '
      'scrollback, launch_command, was_live, updated_at FROM terminal_panes;',
    );
    _db.writeMetadata(kTerminalLayoutBackupAtKey, now);
  }

  /// The grid the app last drew a terminal pane at, or null when it has never
  /// recorded one. A value this cannot parse is no value, never an exception —
  /// it is a hint, and being without one costs what every run used to cost.
  ({int columns, int rows})? loadPaneGrid() {
    final raw = _db.readMetadata(kTerminalPaneGridKey);
    if (raw == null) return null;
    final parts = raw.split('x');
    if (parts.length != 2) return null;
    final columns = int.tryParse(parts.first);
    final rows = int.tryParse(parts.last);
    if (columns == null || rows == null || columns < 1 || rows < 1) return null;
    return (columns: columns, rows: rows);
  }

  void savePaneGrid(({int columns, int rows}) grid) =>
      _db.writeMetadata(kTerminalPaneGridKey, '${grid.columns}x${grid.rows}');

  /// How the middle workspace was divided when the app last saved, or null when
  /// it has never recorded one. Anything unparseable is no tree, never an
  /// exception — the worst case is the one group a first run looks like.
  WorkspaceLayout? loadWorkspace() {
    final raw = _db.readMetadata(kTerminalWorkspaceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PaneLayout.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  void saveWorkspace(WorkspaceLayout? tree) => _db.writeMetadata(
    kTerminalWorkspaceKey,
    tree == null ? '' : jsonEncode(tree.toJson()),
  );

  StoredTerminalLayout loadLayout() {
    final layout = _load('terminal_tabs', 'terminal_panes');
    // Reading the live tables *is* learning what the store holds, so priming
    // the record here makes the first save after a restore free.
    _writtenScrollback
      ..clear()
      ..addEntries([
        for (final tab in [...layout.tabs, ...layout.detached])
          for (final pane in tab.panes) MapEntry(pane.id, pane.scrollback),
      ]);
    return layout;
  }

  /// The layout as it stood immediately before the last save that emptied it,
  /// or empty when no save ever has.
  StoredTerminalLayout loadBackup() =>
      _load('terminal_tabs_backup', 'terminal_panes_backup');

  StoredTerminalLayout _load(String tabTable, String paneTable) {
    final tabRows = _db.query(
      'SELECT id, layout, focused_pane_id, is_active, detached '
      'FROM $tabTable ORDER BY ordinal;',
    );
    if (tabRows.isEmpty) return StoredTerminalLayout.empty;

    final tabs = <StoredTerminalTab>[];
    final detached = <StoredTerminalTab>[];
    String? activeTabId;
    for (final row in tabRows) {
      final id = row['id']! as String;
      final layout = _layoutFrom(row['layout'] as String?);
      if (layout == null) continue;
      final isDetached = boolFromInt(row['detached']);

      final paneRows = _db.query(
        'SELECT id, profile_id, title, working_directory, scrollback, '
        'launch_command, was_live FROM $paneTable WHERE tab_id = ? '
        'ORDER BY ordinal;',
        [id],
      );
      (isDetached ? detached : tabs).add(
        StoredTerminalTab(
          id: id,
          layout: layout,
          detached: isDetached,
          focusedPaneId: row['focused_pane_id'] as String?,
          panes: [
            for (final pane in paneRows)
              StoredTerminalPane(
                id: pane['id']! as String,
                tabId: id,
                profileId: pane['profile_id']! as String,
                title: pane['title']! as String,
                workingDirectory: pane['working_directory'] as String?,
                scrollback: pane['scrollback']! as String,
                agentLaunch: _agentLaunchFrom(
                  pane['launch_command'] as String?,
                ),
                wasLive: boolFromInt(pane['was_live']),
              ),
          ],
        ),
      );
      if (!isDetached && boolFromInt(row['is_active'])) activeTabId = id;
    }

    return StoredTerminalLayout(
      tabs: tabs,
      detached: detached,
      activeTabId: activeTabId,
    );
  }

  void clear() {
    _db.execute('DELETE FROM terminal_tabs;');
    _writtenScrollback.clear();
  }

  /// Parses a stored agent launch, treating anything unreadable as "no agent" —
  /// the pane comes back as a plain restored buffer rather than not at all.
  static AgentPaneLaunch? _agentLaunchFrom(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return AgentPaneLaunch.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  /// Parses stored layout JSON, treating anything unreadable as "no layout".
  static PaneLayout? _layoutFrom(String? raw) {
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    return PaneLayout.fromJson(decoded);
  }
}

final terminalLayoutDaoProvider = Provider<TerminalLayoutDao>(
  (ref) => TerminalLayoutDao(ref.watch(databaseProvider)),
);
