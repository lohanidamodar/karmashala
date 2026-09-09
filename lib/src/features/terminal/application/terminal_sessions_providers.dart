part of 'terminal_sessions_controller.dart';

final terminalSessionsControllerProvider =
    NotifierProvider<TerminalSessionsController, TerminalSessionsState>(
      TerminalSessionsController.new,
    );

/// The terminal's tab topology: which tabs exist, in what order, holding which
/// panes.
///
/// The narrow half of the terminal state. Watching this instead of the whole
/// [TerminalSessionsState] is what stops a process dying in one pane rebuilding
/// every terminal child: the controller hands back the *same* tab list unless
/// the tabs themselves changed, so `select` has something to compare.
final terminalTabsProvider = Provider<List<TerminalTab>>(
  (ref) => ref.watch(terminalSessionsControllerProvider.select((s) => s.tabs)),
);

/// How the middle workspace is divided into groups — see [WorkspaceLayout].
///
/// Null before anything is open. Compared by identity, like the tab list beside
/// it, so a publish that did not move a group wakes nobody.
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

/// The tabs in one group, in the order its strip shows them.
///
/// A family, so opening a tab in one group leaves the other groups' strips
/// alone. It recomputes only when the tree or the tab list moves — the two
/// things that can change the answer.
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

/// The panes a resume is offered for — see
/// [TerminalSessionsController.restoredAgentPanes].
///
/// Watches the tab shape and the liveness projection, and nothing else: a
/// pane's agent-ness is fixed for the life of its instance, and an instance is
/// only ever adopted or released alongside a liveness change, so those two
/// moving is exactly the condition that can change this answer. Both are
/// identity-compared views the controller rebuilds only when they change (see
/// `_tabsMutated` and friends), so this recomputes on a layout change rather
/// than on every publish.
///
/// A consumer that only wants the number `select`s `length` off it, which is
/// what keeps the tab strip from rebuilding while somebody types.
final restoredAgentPanesProvider = Provider<List<String>>((ref) {
  ref.watch(
    terminalSessionsControllerProvider.select((s) => (s.tabs, s.liveness)),
  );
  return ref
      .read(terminalSessionsControllerProvider.notifier)
      .restoredAgentPanes();
});

/// Whether one pane has a process behind it.
///
/// A family, so a process exiting repaints that pane's status bar and its tab's
/// dot rather than every consumer of the layout.
final terminalPaneLivenessProvider = Provider.family<PaneLiveness, String>(
  (ref, paneId) => ref.watch(
    terminalSessionsControllerProvider.select((s) => s.livenessOf(paneId)),
  ),
);

/// The object currently behind pane [paneId] — the thing a view has to rebuild
/// against when it is swapped out from under it.
///
/// **The narrow watch has a hole in it, and this is the patch.**
/// [terminalTabsProvider] and [terminalActiveTabIdProvider] are what
/// `TerminalPaneStack` watches, and neither of them moves when
/// [TerminalSessionsController.startPane] runs: starting a pane changes no
/// tab's shape and no tab's position, so `_tabsView` is handed back by identity
/// and `select` correctly concludes nothing happened. But `startPane` releases
/// the pane's instance and adopts a brand new one — new `Terminal`, new
/// `FocusNode`, new `ScrollController` — so "nothing happened" was wrong about
/// the one thing that matters. Measured, with a widget test over the real
/// panel: after a restart the new node reported `context == null` and
/// `ancestors == 0`, i.e. it had never been attached to anything, because the
/// stack never rebuilt and `TerminalPaneView` was still rendering the *disposed*
/// instance. `requestFocus()` on an unattached node is a no-op that reports no
/// error, which is exactly the shape of the bug the owner saw: *"after resume
/// sometimes i'm unable to focus to the claude prompt"* — and why the pane also
/// showed no new prompt, since the buffer on screen belonged to the dead
/// session.
///
/// Sometimes, rather than always, because any *other* rebuild of the stack
/// picks the swap up in passing — changing the font size, importing a theme,
/// opening or closing a tab. So the pane came back typable whenever something
/// unrelated happened to rebuild, and stayed dead when nothing did.
///
/// A family watching the whole state rather than a `select`: what changes is
/// the identity of an object the state does not carry, so there is nothing to
/// select on. Recomputing is a map lookup, and `Provider` only notifies when
/// the value it returns actually differs — so a pane whose instance did not
/// move still costs its consumers nothing, which is the property
/// [terminalTabsProvider] exists to protect.
///
/// `autoDispose`, unlike its sibling above, because a family keyed by pane id
/// otherwise keeps one entry per pane the layout has *ever* held for the
/// life of the container. Nothing outside a mounted pane view asks this
/// question, and a pane whose view is gone can be asked again for the price of
/// a map lookup when it comes back.
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

/// Which face each workspace group's active tab is showing: `true` for its
/// terminal, `false` for its conversation. A group with no entry shows its
/// terminal.
///
/// **Per group, because a tab owns both faces.** A tab carries a session, a
/// terminal view, a chat view and a status strip as one thing, so which face is
/// up is a property of the group showing that tab — not of the window. Three
/// agents side by side must be able to show three transcripts at once, which is
/// the whole point of the layout.
///
/// One notifier holding a map rather than a family, so a group that collapses
/// leaves nothing behind: [forget] prunes it. Consumers read one group's entry
/// through [terminalVisibleInGroupProvider], which `select`s it, so switching
/// one group's face wakes that group and nobody else.
///
/// Defaults to the **terminal**: the app is terminal-primary, so the terminal
/// is what it rests on and the conversation is what you switch to. It was the
/// other way once, which left every path that wanted the terminal writing
/// `true` to correct it, each one a chance to correct it a frame too late.
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
///
/// Read-only on purpose. Every writer has to say which group it is changing,
/// and the compiler is what makes them: pointing them all at the focused group
/// looks correct with one group and is wrong the moment there are two.
final terminalVisibleProvider = Provider<bool>((ref) {
  final group = ref.watch(focusedWorkspaceGroupProvider);
  return group == null || ref.watch(terminalVisibleInGroupProvider(group));
});

/// Whether **any** group is showing a conversation.
///
/// What a cost gate on transcript work asks now that more than one can be up at
/// once — see `chatTranscriptPollingProvider`.
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
