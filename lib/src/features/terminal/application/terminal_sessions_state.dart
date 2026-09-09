part of 'terminal_sessions_controller.dart';

/// One tab: a tree of regions and which pane has focus.
///
/// [focusedPaneId] is always the front pane of its own region — a pane stacked
/// behind another is not somewhere the keyboard can be. Bringing a pane forward
/// and focusing it are therefore the same act; see
/// [TerminalSessionsController.focusPane].
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

/// A session whose view was closed but whose process was left running.
///
/// This is what separates session lifetime from view lifetime: closing a tab
/// removes the *view*, and the build, dev server or agent inside carries on in
/// the background until the user ends it or the app quits.
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

  /// Per-pane working directory, republished whenever a shell reports a `cd`
  /// (OSC 7) — so the tab label, and anything else naming a pane by where it
  /// is, follows the shell instead of the directory it was launched in.
  ///
  /// Its own projection rather than a flag on the tab list, for the same reason
  /// [liveness] is one: a `cd` in a background pane must not rebuild the tab
  /// strip.
  final Map<String, String?> workingDirectories;

  /// Incremented on every publish so title and metadata watchers can detect
  /// mutations even when tab layout is structurally identical.
  final int titleRevision;

  bool get isEmpty => tabs.isEmpty;

  /// Liveness of [paneId]. An unknown pane is treated as not running: the
  /// safe answer, since the only way to be live is to be tracked.
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

  /// Equal when every part is the **same object**.
  ///
  /// The controller rebuilds each collection only when that collection changed
  /// (see `_tabsMutated` and friends), so identity here is the whole point:
  /// a consumer selecting `state.tabs` is no longer told to rebuild because a
  /// process exited somewhere, and a publish that changed nothing tells nobody
  /// anything. A deep comparison would give the same answer at O(N) per
  /// publish, which is the cost being removed.
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
    titleRevision,
  );
}
