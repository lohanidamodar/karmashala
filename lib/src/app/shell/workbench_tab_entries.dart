part of 'workbench.dart';

// Every terminal tab as the picker lists them, and the two questions that
// decide what each row says.

/// Whether group [groupId] is showing terminal **panes** right now.
///
/// Two surfaces can be up instead: the conversation, and the empty state a
/// session with no pane of ours gets ([_hostedSelection]). While either is, no
/// terminal tab is on screen in that group — so none of its tabs may draw as
/// the active one, in the strip or in the picker.
///
/// A null [groupId] means the focused group, for the picker, which lists the
/// window's tabs and marks the one the keyboard is in.
bool _showingPanes(WidgetRef ref, {String? groupId}) {
  final group = groupId ?? ref.watch(focusedWorkspaceGroupProvider);
  // Before the window has a workspace there is nothing but the terminal.
  if (group == null) return true;
  if (!ref.watch(terminalVisibleInGroupProvider(group))) return false;
  return _hostedSelection(ref, group) == null;
}

/// Every terminal tab, as [TabPicker] lists them.
///
/// Top-level because two things open that picker on the same list: the strip's
/// overflow button, and quick open's "Switch terminal tab…". Built only while
/// the picker is up, because this is the expensive half — telling two `zsh`
/// tabs apart means knowing which session runs in which pane, and that is a
/// query the strip itself never needs.
List<TabEntry> terminalTabEntries(WidgetRef ref) {
  final terminals = ref.watch(terminalSessionsControllerProvider);
  final sessions = ref.read(terminalSessionsControllerProvider.notifier);
  // Adopting a pane, or launching into one, rewrites `pane_id` on the row; a
  // rename changes what a tab is called.
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.title,
    SessionChangeKind.placement,
  });
  // The panes that exist, not every session ever opened. The pane index makes
  // this proportional to the tabs on screen — the same narrowing
  // `activePaneSessionIdProvider` already made, and for the same reason: this
  // was a full table scan run to label a strip of a dozen tabs.
  final titles = <String, String>{
    for (final record in ref.read(sessionDaoProvider).getByPaneIds([
      for (final tab in terminals.tabs) ...tab.layout.panes,
    ]))
      if (record.paneId != null) record.paneId!: record.title,
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
          // A document is not a process, so it has neither a liveness to
          // report nor a shell's glyph — "not running" would be true of a page
          // and would say nothing about it.
          detail:
              _isDocumentTab(tab) || sessions.livenessForTab(tab.id).isLive
              ? null
              : 'not running',
          icon: _isDocumentTab(tab) ? AppIcons.gearSix : AppIcons.terminal,
          onSelect: () => activateTerminalTab(ref, tab.id),
        ),
        active: onPanes && tab.id == active,
        onClose: () => sessions.closeTab(tab.id),
      ),
  ];
}

/// Whether every pane in [tab] is a surface the workbench draws itself — the
/// Settings tab, and nothing else so far.
bool _isDocumentTab(TerminalTab tab) => tab.layout.panes.every(isDocumentPane);

/// Where a tab is: the session running in its focused pane, the directory
/// that pane is in, or both.
///
/// Without it a window full of `zsh` tabs is a list of identical rows, and a
/// picker you cannot pick from is not an answer to anything.
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
