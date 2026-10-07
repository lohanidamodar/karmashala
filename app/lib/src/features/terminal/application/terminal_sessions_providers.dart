part of 'terminal_sessions_controller.dart';

final terminalSessionsControllerProvider =
    NotifierProvider<TerminalSessionsController, TerminalSessionsState>(
      TerminalSessionsController.new,
    );

/// Whether the terminal has been opened this run, asked without opening it.
/// `ref.exists` alone records no dependency, so a reader that asked before the
/// terminal opened would keep its answer; the controller re-asks this one.
final terminalSessionsOpenedProvider = Provider<bool>(
  (ref) => ref.exists(terminalSessionsControllerProvider),
);

/// The terminal's tab topology. Watching this instead of the whole
/// [TerminalSessionsState] is what stops a process dying in one pane rebuilding
/// every terminal child — the tab list comes back by identity unless it moved.
final terminalTabsProvider = Provider<List<TerminalTab>>(
  (ref) => ref.watch(terminalSessionsControllerProvider.select((s) => s.tabs)),
);

/// How the middle workspace is divided into groups — see [WorkspaceLayout].
/// Null before anything is open, and compared by identity, so a publish that
/// did not move a group wakes nobody.
final workspaceLayoutProvider = Provider<WorkspaceLayout?>(
  (ref) =>
      ref.watch(terminalSessionsControllerProvider.select((s) => s.workspace)),
);

/// The group the keyboard is in.
final focusedWorkspaceGroupProvider = Provider<String?>(
  (ref) => ref.watch(
    terminalSessionsControllerProvider.select((s) => s.focusedGroupId),
  ),
);

/// The tabs in one group, in the order its strip shows them. A family, so
/// opening a tab in one group leaves the other groups' strips alone.
final workspaceGroupTabsProvider = Provider.autoDispose
    .family<List<TerminalTab>, String>((ref, groupId) {
      ref.watch(
        terminalSessionsControllerProvider.select((s) => (s.workspace, s.tabs)),
      );
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .tabsInGroup(groupId);
    });

/// The tab group [groupId] is showing, or null while the group is empty.
final workspaceGroupActiveTabProvider = Provider.autoDispose
    .family<String?, String>((ref, groupId) {
      ref.watch(terminalSessionsControllerProvider.select((s) => s.workspace));
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .activeTabInGroup(groupId);
    });

/// Whether the focused group has room to be split along an axis. A bool per
/// axis, so dragging a divider wakes a button only as it crosses the floor.
final workspaceSplitRoomProvider = Provider.autoDispose.family<bool, SplitAxis>(
  (ref, axis) {
    ref.watch(
      terminalSessionsControllerProvider.select(
        (s) => (s.workspace, s.focusedGroupId),
      ),
    );
    return ref
        .read(terminalSessionsControllerProvider.notifier)
        .canSplitWorkspace(axis);
  },
);

/// Which tab is in front.
final terminalActiveTabIdProvider = Provider<String?>(
  (ref) => ref.watch(
    terminalSessionsControllerProvider.select((s) => s.activeTabId),
  ),
);

/// Sessions running with no tab.
final terminalDetachedProvider = Provider<List<DetachedSession>>(
  (ref) =>
      ref.watch(terminalSessionsControllerProvider.select((s) => s.detached)),
);

/// The panes a resume is offered for. Watches the tab shape and the liveness
/// projection and nothing else — a pane's agent-ness is fixed for the life of
/// its instance, so only those two moving can change the answer.
final restoredAgentPanesProvider = Provider<List<String>>((ref) {
  ref.watch(
    terminalSessionsControllerProvider.select((s) => (s.tabs, s.liveness)),
  );
  return ref
      .read(terminalSessionsControllerProvider.notifier)
      .restoredAgentPanes();
});

/// Whether one pane has a process behind it. A family, so an exit repaints that
/// pane's status bar and its tab's dot rather than every consumer.
final terminalPaneLivenessProvider = Provider.family<PaneLiveness, String>(
  (ref, paneId) => ref.watch(
    terminalSessionsControllerProvider.select((s) => s.livenessOf(paneId)),
  ),
);

/// The object currently behind pane [paneId]: `startPane` swaps an instance
/// without moving a tab, so the view kept rendering a disposed one.
final terminalPaneInstanceProvider = Provider.autoDispose
    .family<TerminalInstance?, String>((ref, paneId) {
      ref.watch(terminalSessionsControllerProvider);
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
    });

/// The title of tab [tabId], reactive to session renames and OSC updates.
final terminalTabTitleProvider = Provider.autoDispose.family<String, String>((
  ref,
  tabId,
) {
  ref.watch(terminalSessionsControllerProvider.select((s) => s.titleRevision));
  return ref
      .read(terminalSessionsControllerProvider.notifier)
      .titleForTab(tabId);
});

/// The title of pane [paneId], reactive to session renames and OSC updates.
final terminalPaneTitleProvider = Provider.autoDispose.family<String, String>((
  ref,
  paneId,
) {
  ref.watch(terminalSessionsControllerProvider.select((s) => s.titleRevision));
  return ref
      .read(terminalSessionsControllerProvider.notifier)
      .titleForPane(paneId);
});

/// The face each workspace group was **put** on; a group with no entry rests on
/// [groupOpensOnChatProvider]'s answer. **Per group, not per window**: three
/// transcripts must fit at once.
class TerminalFacesController extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void show(String groupId, {required bool terminal}) {
    if (state[groupId] == terminal) return;
    state = {...state, groupId: terminal};
  }

  void toggle(String groupId) => show(
    groupId,
    terminal: !(state[groupId] ?? !ref.read(groupOpensOnChatProvider(groupId))),
  );

  /// Lets group [groupId] go back to the face its active tab opens on.
  void reset(String groupId) {
    if (!state.containsKey(groupId)) return;
    state = {...state}..remove(groupId);
  }

  /// Drops the entries of groups that no longer exist.
  void forget(Set<String> live) {
    if (state.keys.every(live.contains)) return;
    state = {
      for (final entry in state.entries)
        if (live.contains(entry.key)) entry.key: entry.value,
    };
  }
}

final terminalFacesProvider =
    NotifierProvider<TerminalFacesController, Map<String, bool>>(
      TerminalFacesController.new,
    );

/// Whether [tab] runs an agent session in a terminal pane — a tab with a chat
/// to open on. A plain shell, a document and an ACP chat have none.
bool tabRunsTerminalSession(PaneSessions panes, TerminalTab? tab) =>
    tab != null &&
    tab.layout.panes.any(
      (paneId) =>
          chatPaneSessionId(paneId) == null && panes.sessionOf(paneId) != null,
    );

/// Whether group [groupId] rests on its chat while nobody has put it on a
/// face: its active tab runs a terminal agent session, and the person opens
/// those in chat ([sessionsOpenInChatProvider]).
final groupOpensOnChatProvider = Provider.family<bool, String>((ref, groupId) {
  // Asked without opening the terminal: with none, there is no tab to run one.
  if (!ref.watch(terminalSessionsOpenedProvider)) return false;
  final tab = ref.watch(
    terminalSessionsControllerProvider.select((s) {
      final tabId = s.workspace?.groupById(groupId)?.activePaneId;
      return s.tabs.where((t) => t.id == tabId).firstOrNull;
    }),
  );
  return tabRunsTerminalSession(ref.watch(paneSessionsProvider), tab) &&
      ref.watch(sessionsOpenInChatProvider);
});

/// Whether group [groupId] is showing its terminal rather than its chat.
final terminalVisibleInGroupProvider = Provider.family<bool, String>(
  (ref, groupId) =>
      ref.watch(terminalFacesProvider.select((f) => f[groupId])) ??
      !ref.watch(groupOpensOnChatProvider(groupId)),
);

/// The **focused** group's face — what a command with no group in hand means.
/// Read-only on purpose: a writer has to name its group, because the focused
/// one looks correct with one group and is wrong the moment there are two.
final terminalVisibleProvider = Provider<bool>((ref) {
  final group = ref.watch(focusedWorkspaceGroupProvider);
  return group == null || ref.watch(terminalVisibleInGroupProvider(group));
});

/// Whether **any** group is showing a conversation — what a cost gate on
/// transcript work asks now that more than one can be up at once.
final anyChatVisibleProvider = Provider<bool>((ref) {
  final faces = ref.watch(terminalFacesProvider);
  if (faces.values.any((terminal) => !terminal)) return true;
  if (!ref.watch(terminalSessionsOpenedProvider)) return false;
  final groups = ref.watch(workspaceLayoutProvider)?.groups ?? const [];
  return groups.any(
    (group) =>
        !faces.containsKey(group.id) &&
        ref.watch(groupOpensOnChatProvider(group.id)),
  );
});

/// Whether the terminal fills the whole window rather than sitting in its dock.
class TerminalMaximizedController extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final terminalMaximizedProvider =
    NotifierProvider<TerminalMaximizedController, bool>(
      TerminalMaximizedController.new,
    );
