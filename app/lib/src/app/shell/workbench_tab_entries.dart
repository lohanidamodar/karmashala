part of 'workbench.dart';

/// Whether group [groupId] is showing **its tabs** right now — while a session
/// with no tab of its own is up, no tab there may draw as active. The chat
/// view is not that: it is the active tab's own session drawn as a
/// conversation, so the tab stays lit (owner, 2026-09-28: an unlit tab in
/// chat view was confusing).
bool _showingPanes(WidgetRef ref, {String? groupId}) {
  final group = groupId ?? ref.watch(focusedWorkspaceGroupProvider);
  // Before the window has a workspace there is nothing but the terminal.
  if (group == null) return true;
  return _hostedSelection(ref, group) == null;
}

/// Every terminal tab, as [TabPicker] lists them. Built only while the picker is
/// up: telling two `zsh` tabs apart needs what the strip never asks for.
List<TabEntry> terminalTabEntries(WidgetRef ref) {
  final terminals = ref.watch(terminalSessionsControllerProvider);
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  // A rename changes what a tab is called.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.title,
  });
  final panes = ref.watch(paneSessionsProvider);
  final rows = ref.read(sessionsDataProvider);
  final titles = <String, String>{
    for (final tab in terminals.tabs)
      if (panes.sessionOf(tab.focusedPaneId) case final sessionId?)
        if (rows.getById(sessionId) case final record?)
          tab.focusedPaneId: record.title,
  };
  final onPanes = _showingPanes(ref);
  final active = terminals.activeTabId;
  return [
    for (final tab in terminals.tabs)
      TabEntry(
        item: QuickOpenItem(
          id: 'tab/${tab.id}',
          group: QuickOpenGroup.tabs,
          title: sessions.titleForTab(tab.id),
          subtitle: _whereabouts(tab, titles, sessions),
          // A document is not a process, so it has no liveness to report —
          // "not running" would be true of a page and say nothing about it.
          detail: _isDocumentTab(tab) || sessions.livenessForTab(tab.id).isLive
              ? null
              : 'not running',
          icon:
              documentIconFor(tab) ??
              (_isChatTab(tab) ? AppIcons.chatCircle : AppIcons.terminal),
          onSelect: () => activateTerminalTab(ref, tab.id),
        ),
        active: onPanes && tab.id == active,
        unsaved: _tabHasUnsaved(ref, tab),
        onClose: () => closeEditors(ref.context, ref, [
          tab.id,
        ], () => sessions.closeTab(tab.id)),
      ),
  ];
}

/// Whether [tab] holds a file with edits that are not on disk — so the picker
/// can say so before offering to close it.
bool _tabHasUnsaved(WidgetRef ref, TerminalTab tab) {
  if (_tabHasConflictedNote(ref, tab)) return true;
  final paths = [
    for (final paneId in tab.layout.panes) ?editorPanePath(paneId),
  ];
  if (paths.isEmpty) return false;
  return ref.watch(
    dirtyDocumentPathsProvider.select((dirty) => paths.any(dirty.contains)),
  );
}

/// Whether [tab] holds a note whose close would have to ask: one that changed
/// elsewhere under unsaved edits. Anything else is written on the way out.
bool _tabHasConflictedNote(WidgetRef ref, TerminalTab tab) {
  final ids = noteIdsIn([tab]);
  if (ids.isEmpty) return false;
  return ref.watch(
    conflictedNoteIdsProvider.select(
      (conflicted) => ids.any(conflicted.contains),
    ),
  );
}

/// Whether every pane in [tab] is a surface the workbench draws itself.
bool _isDocumentTab(TerminalTab tab) => tab.layout.panes.every(isDocumentPane);

/// Whether [tab] is one session's conversation and nothing else.
bool _isChatTab(TerminalTab tab) =>
    tab.layout.panes.length == 1 && isChatPane(tab.layout.panes.single);

/// The glyph a document tab wears in place of a liveness dot, or null when the
/// tab holds a process. One table, so the strip and the picker cannot disagree.
IconData? documentIconFor(TerminalTab tab) {
  if (tab.layout.panes.length != 1) return null;
  final paneId = tab.layout.panes.single;
  // A chat pane wears its session's status, as an agent's terminal tab does.
  if (isChatPane(paneId)) return null;
  if (isSettingsPane(paneId)) return AppIcons.gearSix;
  if (isDevicePane(paneId)) return AppIcons.deviceMobile;
  if (isDevicePreviewPane(paneId)) return AppIcons.deviceMobile;
  if (isUsagePane(paneId)) return AppIcons.chartBar;
  if (isStoresPane(paneId)) return AppIcons.package;
  if (isLogsPane(paneId)) return AppIcons.article;
  if (isOverviewPane(paneId)) return AppIcons.squaresFour;
  if (isRunningPane(paneId)) return AppIcons.listMagnifyingGlass;
  if (isEditorPane(paneId)) return AppIcons.fileCode;
  if (isDiffPane(paneId)) return AppIcons.gitDiff;
  if (isNotePane(paneId)) return AppIcons.note;
  if (isFilesPane(paneId)) return AppIcons.folderOpen;
  if (isBrowserPane(paneId)) return AppIcons.globe;
  return null;
}

/// Where a tab is: the session running in its focused pane, the directory that
/// pane is in, or both — without it a window of `zsh` tabs is identical rows.
String? _whereabouts(
  TerminalTab tab,
  Map<String, String> sessionTitles,
  TerminalSessionsController sessions,
) {
  final paneId = tab.focusedPaneId;
  final parts = [
    ?sessionTitles[paneId],
    ?sessions.instanceFor(paneId)?.workingDirectory,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
