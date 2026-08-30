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

  /// Replaces the stored workspace with [tabs].
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
    _db.transaction(() {
      final stored = storedTabCount();
      if (tabs.isEmpty || (!userClosed && tabs.length < stored)) {
        _backupWorkspace(now);
      }
      // Panes cascade with their tab.
      _db.execute('DELETE FROM terminal_tabs;');
      for (var i = 0; i < tabs.length; i++) {
        final tab = tabs[i];
        _db.execute(
          'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
          'is_active, detached, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
          [
            tab.id,
            i,
            jsonEncode(tab.layout.toJson()),
            tab.focusedPaneId,
            intFromBool(!tab.detached && tab.id == activeTabId),
            intFromBool(tab.detached),
            now,
          ],
        );
        for (var j = 0; j < tab.panes.length; j++) {
          final pane = tab.panes[j];
          _db.execute(
            'INSERT INTO terminal_panes (id, tab_id, ordinal, profile_id, '
            'title, working_directory, scrollback, launch_command, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
            [
              pane.id,
              tab.id,
              j,
              pane.profileId,
              pane.title,
              pane.workingDirectory,
              pane.scrollback,
              pane.agentLaunch == null
                  ? null
                  : jsonEncode(pane.agentLaunch!.toJson()),
              now,
            ],
          );
        }
      }
    });
  }

  /// Updates one pane's scrollback in place — the autosave path, which must not
  /// rewrite the whole workspace every tick.
  void saveScrollback(String paneId, String scrollback) {
    _db.execute(
      'UPDATE terminal_panes SET scrollback = ?, updated_at = ? WHERE id = ?;',
      [scrollback, isoFromDate(DateTime.now()), paneId],
    );
  }

  /// Copies the stored workspace into the backup tables, replacing whatever was
  /// there. Does nothing when there is nothing to lose.
  ///
  /// Called from inside [saveWorkspace]'s transaction, so a failure anywhere in
  /// the save rolls the copy back with it — the backup can never be a snapshot
  /// of a delete that did not happen.
  void _backupWorkspace(String now) {
    if (storedTabCount() == 0) return;
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

  StoredTerminalWorkspace loadWorkspace() =>
      _load('terminal_tabs', 'terminal_panes');

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

  void clear() => _db.execute('DELETE FROM terminal_tabs;');

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
