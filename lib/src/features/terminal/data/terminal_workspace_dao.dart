import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/agent_pane_launch.dart';
import '../domain/pane_layout.dart';

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
  });

  final String id;
  final String tabId;
  final String profileId;
  final String title;
  final String? workingDirectory;
  final String scrollback;

  /// The agent CLI this pane ran, when it ran one. A shell pane stores `null`.
  final AgentPaneLaunch? agentLaunch;
}

/// One persisted tab: its pane tree plus the panes the tree references.
///
/// A **detached** session — one the user closed the tab of while it kept
/// running — is stored the same way, as a single-pane row with [detached] set.
/// It is not a tab and never comes back as one; sharing the table just means its
/// scrollback is preserved by exactly the same code path, rather than being the
/// one kind of session that silently loses its history on quit.
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
class StoredTerminalWorkspace {
  const StoredTerminalWorkspace({
    required this.tabs,
    required this.activeTabId,
    this.detached = const [],
  });

  static const empty = StoredTerminalWorkspace(tabs: [], activeTabId: null);

  final List<StoredTerminalTab> tabs;

  /// Sessions that had no tab when the app last exited, in the order they were
  /// detached.
  final List<StoredTerminalTab> detached;

  final String? activeTabId;
}

/// The `app_metadata` key stamped when a save emptied a non-empty workspace.
///
/// The backup rows carry their own `updated_at`, but those are the timestamps of
/// the *save that stored them*, not of the emptying — this is when the copy was
/// taken, which is the question anyone recovering one is actually asking.
const kTerminalWorkspaceBackupAtKey = 'terminal.workspace_backup_at';

/// Reads and writes the terminal workspace (schema v7, backup tables v11) with
/// hand-written SQL.
///
/// Loading is deliberately forgiving: a row this code cannot parse is skipped
/// rather than thrown on, because a corrupt layout must never make the terminal
/// unopenable.
class TerminalWorkspaceDao {
  TerminalWorkspaceDao(this._db);

  final AppDatabase _db;

  /// The scrollback text this dao last saw in the store, by pane id.
  ///
  /// Everything else a save compares, it reads back from the store itself —
  /// authoritative, and cheap because those columns are ids, ordinals and a
  /// layout tree. Scrollback is the one exception: a pane holds up to a full
  /// durable window of SGR-dense text and there are up to a hundred of them, so
  /// reading it back to compare would cost about what rewriting it costs, which
  /// defeats the point.
  ///
  /// So for that one column the dao keeps its own record, and the fallback
  /// whenever it has none is to **write**. Nothing else writes the column:
  /// [saveScrollback] is the only other writer and keeps this in step,
  /// [loadWorkspace] primes it with what it has just read, and [clear] empties
  /// it.
  final Map<String, String> _writtenScrollback = {};

  /// How many tabs (including detached rows) the store currently holds.
  ///
  /// The controller's guard needs to know whether an empty save would *destroy*
  /// something, and a count is the cheapest form of that question — it reads no
  /// scrollback.
  int storedTabCount() {
    final rows = _db.query('SELECT COUNT(*) AS n FROM terminal_tabs;');
    if (rows.isEmpty) return 0;
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Makes the stored workspace be [tabs], by writing **only the rows that
  /// differ from what is stored**.
  ///
  /// This used to be `DELETE FROM terminal_tabs;` followed by an INSERT per tab
  /// and per pane, every pane carrying its whole scrollback. The bindings are
  /// synchronous (`package:sqlite3`), the controller calls this on every
  /// structural change, and `tool/benchmark/terminal_scale_bench.dart` measured
  /// the result at **645 ms** at the hundred-pane scale target — a frame the
  /// user watches go by every time they resume a session, which is the owner's
  /// "resuming session still makes ui laggy" against 1.1.5.
  ///
  /// Resuming a session adds one pane to one tab. So the save now costs one
  /// upsert per row that actually moved plus one delete per row that actually
  /// vanished, and nothing per row that is already correct. Two small SELECTs
  /// of the stored *structure* (never the scrollback) say which is which, so
  /// ordinals and the delete-what-vanished semantics the full replace got for
  /// free are still read from the store rather than assumed — see
  /// [_writeChangedRows] and `workspace_write_cost_test.dart`.
  ///
  /// A copy of the outgoing workspace is taken first, inside the same
  /// transaction, when this save **loses** something:
  ///
  /// * it empties a store that was not empty — the Loop 48 shape, whether or not
  ///   the user asked for it; or
  /// * it stores fewer tabs than were there and [userClosed] is false, so
  ///   nothing the user did accounts for the shrink. Observed for real: a
  ///   workspace whose panes could no longer be rebuilt restored as zero tabs,
  ///   the terminal opened one for the user, and that one-tab save replaced
  ///   eight stored ones. The controller's guard does not cover it because the
  ///   save is not empty — but it is still a loss, and a loss with a copy behind
  ///   it is a bug rather than a bereavement.
  ///
  /// A save the user's own closes account for costs nothing extra, which is what
  /// keeps closing a tab as cheap as it was.
  void saveWorkspace(
    List<StoredTerminalTab> tabs, {
    String? activeTabId,
    bool userClosed = false,
  }) {
    final now = isoFromDate(DateTime.now());
    final written = _db.transaction(() {
      final stored = storedTabCount();
      if (tabs.isEmpty || (!userClosed && tabs.length < stored)) {
        _backupWorkspace(now, stored);
      }
      return _writeChangedRows(tabs, activeTabId, now);
    });
    // Adopted only once the transaction has committed. A save that threw
    // half-way is rolled back in full, and a record claiming rows that were
    // rolled back is the one way this dao could skip a write it owed.
    _writtenScrollback
      ..clear()
      ..addAll(written);
  }

  /// The body of [saveWorkspace]: upsert what moved, delete what vanished.
  ///
  /// The stored **structure** is read first — every tab and pane row minus the
  /// scrollback column, which is the only expensive one. That read is what lets
  /// this keep the two properties a full replace never had to think about:
  ///
  /// * **Ordinals.** Position is written from the incoming list's index every
  ///   time it disagrees with the stored one, so reordering tabs or closing one
  ///   out of the middle renumbers exactly the rows that moved and leaves no
  ///   gap.
  /// * **Delete what vanished.** An id in the store and not in [tabs] is
  ///   deleted outright rather than being left behind by an upsert that never
  ///   ran.
  ///
  /// Order matters, and it is: upserts first, deletes after. A pane that moved
  /// out of a tab that is itself going has to be re-parented *before* that tab
  /// goes, or the foreign key cascade takes it with the tab.
  ///
  /// `ON CONFLICT DO UPDATE` rather than `INSERT OR REPLACE`: REPLACE deletes
  /// the conflicting row before reinserting it, and with `PRAGMA foreign_keys =
  /// ON` that fires `terminal_panes`' `ON DELETE CASCADE` — updating a tab
  /// would silently throw away its panes.
  ///
  /// Returns what [_writtenScrollback] should become, for the caller to adopt
  /// once the transaction has committed.
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
        'launch_command FROM terminal_panes;',
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
        final storedPane = storedPanes[pane.id];
        if (storedPane == null ||
            storedPane['tab_id'] != tab.id ||
            storedPane['ordinal'] != j ||
            storedPane['profile_id'] != pane.profileId ||
            storedPane['title'] != pane.title ||
            storedPane['working_directory'] != pane.workingDirectory ||
            storedPane['launch_command'] != launch ||
            _scrollbackChanged(pane)) {
          _db.execute(
            'INSERT INTO terminal_panes (id, tab_id, ordinal, profile_id, '
            'title, working_directory, scrollback, launch_command, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (id) DO UPDATE SET tab_id = excluded.tab_id, '
            'ordinal = excluded.ordinal, profile_id = excluded.profile_id, '
            'title = excluded.title, '
            'working_directory = excluded.working_directory, '
            'scrollback = excluded.scrollback, '
            'launch_command = excluded.launch_command, '
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
              now,
            ],
          );
          written[pane.id] = pane.scrollback;
        } else {
          // Skipped because the record already matches, so it carries over.
          written[pane.id] = _writtenScrollback[pane.id]!;
        }
      }
    }

    for (final entry in storedPanes.entries) {
      if (livePanes.contains(entry.key)) continue;
      final tabId = entry.value['tab_id'] as String?;
      // A pane whose tab is going too needs no statement of its own — the
      // foreign key cascades — which is what keeps closing a tab one write
      // however many panes were in it.
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
  ///
  /// "No record" counts as changed: the dao only ever skips a write it can
  /// account for.
  bool _scrollbackChanged(StoredTerminalPane pane) {
    final written = _writtenScrollback[pane.id];
    if (written == null) return true;
    // The controller hands back the *same* string instance for a pane whose
    // buffer has not moved (its encoding cache), so the common case settles on
    // a pointer compare and never walks the text.
    return !identical(written, pane.scrollback) && written != pane.scrollback;
  }

  /// Updates one pane's scrollback in place — the autosave path, which must not
  /// rewrite the whole workspace every tick.
  void saveScrollback(String paneId, String scrollback) {
    _db.execute(
      'UPDATE terminal_panes SET scrollback = ?, updated_at = ? WHERE id = ?;',
      [scrollback, isoFromDate(DateTime.now()), paneId],
    );
    // Only for a pane the dao already knows the store holds. An UPDATE that
    // matched no row must not leave a record claiming it did — that record is
    // the one thing a save trusts without re-reading.
    if (_writtenScrollback.containsKey(paneId)) {
      _writtenScrollback[paneId] = scrollback;
    }
  }

  /// Copies the stored workspace into the backup tables, replacing whatever was
  /// there. Does nothing when there is nothing to lose.
  ///
  /// Called from inside [saveWorkspace]'s transaction, so a failure anywhere in
  /// the save rolls the copy back with it — the backup can never be a snapshot
  /// of a delete that did not happen.
  ///
  /// [stored] is the tab count [saveWorkspace] has already taken, passed rather
  /// than counted again.
  void _backupWorkspace(String now, int stored) {
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
      'title, working_directory, scrollback, launch_command, updated_at) '
      'SELECT id, tab_id, ordinal, profile_id, title, working_directory, '
      'scrollback, launch_command, updated_at FROM terminal_panes;',
    );
    _db.writeMetadata(kTerminalWorkspaceBackupAtKey, now);
  }

  StoredTerminalWorkspace loadWorkspace() {
    final workspace = _load('terminal_tabs', 'terminal_panes');
    // Reading the live tables *is* learning what the store holds, so the record
    // a save compares scrollback against costs nothing to bring up to date
    // here. It is also what makes the first save after a restore free rather
    // than a full rewrite of every pane the restore has just read back.
    _writtenScrollback
      ..clear()
      ..addEntries([
        for (final tab in [...workspace.tabs, ...workspace.detached])
          for (final pane in tab.panes) MapEntry(pane.id, pane.scrollback),
      ]);
    return workspace;
  }

  /// The workspace as it stood immediately before the last save that emptied it.
  ///
  /// Empty when no save has ever emptied a non-empty workspace.
  StoredTerminalWorkspace loadBackup() =>
      _load('terminal_tabs_backup', 'terminal_panes_backup');

  StoredTerminalWorkspace _load(String tabTable, String paneTable) {
    final tabRows = _db.query(
      'SELECT id, layout, focused_pane_id, is_active, detached '
      'FROM $tabTable ORDER BY ordinal;',
    );
    if (tabRows.isEmpty) return StoredTerminalWorkspace.empty;

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
        'launch_command FROM $paneTable WHERE tab_id = ? ORDER BY ordinal;',
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
              ),
          ],
        ),
      );
      if (!isDetached && boolFromInt(row['is_active'])) activeTabId = id;
    }

    return StoredTerminalWorkspace(
      tabs: tabs,
      detached: detached,
      activeTabId: activeTabId,
    );
  }

  void clear() {
    _db.execute('DELETE FROM terminal_tabs;');
    _writtenScrollback.clear();
  }

  /// Parses a stored agent launch, treating anything unreadable as "no agent"
  /// — the pane then comes back as a plain restored buffer rather than not at
  /// all.
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

final terminalWorkspaceDaoProvider = Provider<TerminalWorkspaceDao>(
  (ref) => TerminalWorkspaceDao(ref.watch(databaseProvider)),
);
