part of 'terminal_sessions_controller.dart';

/// One tab: a tree of regions and which pane has focus. [focusedPaneId] is
/// always the front pane of its region — a pane stacked behind another is not
/// somewhere the keyboard can be, so activating and focusing are one act.
class TerminalTab {
  const TerminalTab({
    required this.id,
    required this.layout,
    required this.focusedPaneId,
  });

  final String id;
  final PaneLayout layout;
  final String focusedPaneId;

  TerminalTab copyWith({PaneLayout? layout, String? focusedPaneId}) {
    return TerminalTab(
      id: id,
      layout: layout ?? this.layout,
      focusedPaneId: focusedPaneId ?? this.focusedPaneId,
    );
  }
}

/// A session whose view was closed but whose process was left running — what
/// separates session lifetime from view lifetime.
class DetachedSession {
  const DetachedSession({
    required this.paneId,
    required this.title,
    required this.workingDirectory,
    required this.detachedAt,
  });

  final String paneId;
  final String title;
  final String? workingDirectory;
  final DateTime detachedAt;
}

/// Open terminal tabs, which one is active, the sessions running with no tab,
/// and whether each pane actually has a process behind it.
class TerminalSessionsState {
  const TerminalSessionsState({
    this.tabs = const [],
    this.activeTabId,
    this.workspace,
    this.focusedGroupId,
    this.detached = const [],
    this.liveness = const {},
    this.workingDirectories = const {},
    this.launchedSessions = const {},
    this.titleRevision = 0,
  });

  final List<TerminalTab> tabs;
  final String? activeTabId;

  /// How the middle workspace is divided, and which tabs are in each group —
  /// see [WorkspaceLayout]. Null while there is nothing open.
  final WorkspaceLayout? workspace;

  /// The group the keyboard is in. [activeTabId] is its tab on screen, and is
  /// null exactly when that group is still empty.
  final String? focusedGroupId;

  /// Sessions kept running with no tab showing them, newest last.
  final List<DetachedSession> detached;

  /// Per-pane liveness, republished whenever a process exits — so a pane that
  /// died while its tab was in the background still repaints as dead.
  final Map<String, PaneLiveness> liveness;

  /// Per-pane working directory, republished on every OSC 7 `cd`. Its own
  /// projection, so a `cd` in a background pane does not rebuild the tab strip.
  final Map<String, String?> workingDirectories;

  /// Every pane of this window → the session it was opened to run, null for a
  /// shell. Moves only when a pane comes or goes; see [paneSessionsProvider].
  final Map<String, String?> launchedSessions;

  /// Incremented on every publish so title and metadata watchers can detect
  /// mutations even when tab layout is structurally identical.
  final int titleRevision;

  bool get isEmpty => tabs.isEmpty;

  /// Liveness of [paneId]. An unknown pane is not running — the only way to be
  /// live is to be tracked.
  PaneLiveness livenessOf(String paneId) =>
      liveness[paneId] ?? PaneLiveness.exited;

  /// Where pane [paneId] is now, or null for an unknown pane and for one whose
  /// directory was never recorded.
  String? directoryOf(String paneId) => workingDirectories[paneId];

  TerminalTab? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab;
    }
    return null;
  }

  /// Equal when every part is the **same object**: a consumer selecting
  /// `state.tabs` is not woken by a process exiting, and no comparison is O(N).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalSessionsState &&
          identical(other.tabs, tabs) &&
          other.activeTabId == activeTabId &&
          identical(other.workspace, workspace) &&
          other.focusedGroupId == focusedGroupId &&
          identical(other.detached, detached) &&
          identical(other.liveness, liveness) &&
          identical(other.workingDirectories, workingDirectories) &&
          identical(other.launchedSessions, launchedSessions) &&
          other.titleRevision == titleRevision;

  @override
  int get hashCode => Object.hash(
    identityHashCode(tabs),
    activeTabId,
    identityHashCode(workspace),
    focusedGroupId,
    identityHashCode(detached),
    identityHashCode(liveness),
    identityHashCode(workingDirectories),
    identityHashCode(launchedSessions),
    titleRevision,
  );
}
