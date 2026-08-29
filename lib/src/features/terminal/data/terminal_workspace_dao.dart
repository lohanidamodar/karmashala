import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../../../core/database/row_mapping.dart';
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
  });

  final String id;
  final String tabId;
  final String profileId;
  final String title;
  final String? workingDirectory;
  final String scrollback;
}

/// One persisted tab: its pane tree plus the panes the tree references.
class StoredTerminalTab {
  const StoredTerminalTab({
    required this.id,
    required this.layout,
    required this.focusedPaneId,
    required this.panes,
  });

  final String id;
  final PaneLayout layout;
  final String? focusedPaneId;
  final List<StoredTerminalPane> panes;
}

/// Everything needed to bring the terminal back as the user left it.
class StoredTerminalWorkspace {
  const StoredTerminalWorkspace({
    required this.tabs,
    required this.activeTabId,
  });

  static const empty = StoredTerminalWorkspace(tabs: [], activeTabId: null);

  final List<StoredTerminalTab> tabs;
  final String? activeTabId;
}

/// Reads and writes the terminal workspace (schema v7) with hand-written SQL.
///
/// Loading is deliberately forgiving: a row this code cannot parse is skipped
/// rather than thrown on, because a corrupt layout must never make the terminal
/// unopenable.
class TerminalWorkspaceDao {
  TerminalWorkspaceDao(this._db);

  final AppDatabase _db;

  /// Replaces the stored workspace with [tabs].
  void saveWorkspace(List<StoredTerminalTab> tabs, {String? activeTabId}) {
    final now = isoFromDate(DateTime.now());
    _db.transaction(() {
      // Panes cascade with their tab.
      _db.execute('DELETE FROM terminal_tabs;');
      for (var i = 0; i < tabs.length; i++) {
        final tab = tabs[i];
        _db.execute(
          'INSERT INTO terminal_tabs (id, ordinal, layout, focused_pane_id, '
          'is_active, updated_at) VALUES (?, ?, ?, ?, ?, ?);',
          [
            tab.id,
            i,
            jsonEncode(tab.layout.toJson()),
            tab.focusedPaneId,
            intFromBool(tab.id == activeTabId),
            now,
          ],
        );
        for (var j = 0; j < tab.panes.length; j++) {
          final pane = tab.panes[j];
          _db.execute(
            'INSERT INTO terminal_panes (id, tab_id, ordinal, profile_id, '
            'title, working_directory, scrollback, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
            [
              pane.id,
              tab.id,
              j,
              pane.profileId,
              pane.title,
              pane.workingDirectory,
              pane.scrollback,
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

  StoredTerminalWorkspace loadWorkspace() {
    final tabRows = _db.query(
      'SELECT id, layout, focused_pane_id, is_active FROM terminal_tabs '
      'ORDER BY ordinal;',
    );
    if (tabRows.isEmpty) return StoredTerminalWorkspace.empty;

    final tabs = <StoredTerminalTab>[];
    String? activeTabId;
    for (final row in tabRows) {
      final id = row['id']! as String;
      final layout = _layoutFrom(row['layout'] as String?);
      if (layout == null) continue;

      final paneRows = _db.query(
        'SELECT id, profile_id, title, working_directory, scrollback '
        'FROM terminal_panes WHERE tab_id = ? ORDER BY ordinal;',
        [id],
      );
      tabs.add(
        StoredTerminalTab(
          id: id,
          layout: layout,
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
              ),
          ],
        ),
      );
      if (boolFromInt(row['is_active'])) activeTabId = id;
    }

    return StoredTerminalWorkspace(tabs: tabs, activeTabId: activeTabId);
  }

  void clear() => _db.execute('DELETE FROM terminal_tabs;');

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
