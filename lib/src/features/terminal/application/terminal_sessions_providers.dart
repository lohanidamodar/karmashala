part of 'terminal_sessions_controller.dart';

final terminalSessionsControllerProvider =
    NotifierProvider<TerminalSessionsController, TerminalSessionsState>(
      TerminalSessionsController.new,
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
      ref.watch(
        terminalSessionsControllerProvider.select((s) => s.workspace),
      );
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .activeTabInGroup(groupId);
    });

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

/// The object currently behind pane [paneId] — the patch for the hole in the
/// narrow watches above: `startPane` swaps a pane's instance without moving any
/// tab, so the view went on rendering a *disposed* one whose new `FocusNode`
/// was never attached, and `requestFocus()` on that is a silent no-op.
final terminalPaneInstanceProvider = Provider.autoDispose
    .family<TerminalInstance?, String>((ref, paneId) {
      ref.watch(terminalSessionsControllerProvider);
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(paneId);
    });

/// The title of tab [tabId], reactive to session renames and OSC updates.
final terminalTabTitleProvider = Provider.autoDispose
    .family<String, String>((ref, tabId) {
      ref.watch(
        terminalSessionsControllerProvider.select((s) => s.titleRevision),
      );
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .titleForTab(tabId);
    });

/// The title of pane [paneId], reactive to session renames and OSC updates.
final terminalPaneTitleProvider = Provider.autoDispose
    .family<String, String>((ref, paneId) {
      ref.watch(
        terminalSessionsControllerProvider.select((s) => s.titleRevision),
      );
      return ref
          .read(terminalSessionsControllerProvider.notifier)
          .titleForPane(paneId);
    });

/// Which face each workspace group's active tab shows, defaulting to the
/// terminal. **Per group, not per window**: three transcripts must fit at once.
class TerminalFacesController extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void show(String groupId, {required bool terminal}) {
    if ((state[groupId] ?? true) == terminal) return;
    state = {...state, groupId: terminal};
  }

  void toggle(String groupId) =>
      show(groupId, terminal: !(state[groupId] ?? true));

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

/// Whether group [groupId] is showing its terminal rather than its chat.
final terminalVisibleInGroupProvider = Provider.family<bool, String>(
  (ref, groupId) =>
      ref.watch(terminalFacesProvider.select((f) => f[groupId] ?? true)),
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
final anyChatVisibleProvider = Provider<bool>(
  (ref) => ref.watch(
    terminalFacesProvider.select(
      (faces) => faces.values.any((terminal) => !terminal),
    ),
  ),
);

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
