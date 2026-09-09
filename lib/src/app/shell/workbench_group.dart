part of 'workbench.dart';

// One workspace group: its own strip, its own surface, its own bar — and
// the room a workspace split clears before anything is put in it.

/// One **workspace group**: its own tab strip, its own surface, its own status
/// bar. VS Code's editor group, with the whole middle of the window inside it
/// instead of an editor.
///
/// The report: *"every split pane should have it's tabbar and its statusbar,
/// and every split can have multiple tabs dragged to their tab header, like vs
/// code. not like only split the terminal space. split the whole middle
/// workspace."*
///
/// **Everything here reads its own group.** Not the focused one — that is the
/// bug this shape exists to make impossible. A bar wired to "the session the
/// window is about" looks perfect with one group and describes somebody else's
/// session the instant there are two: three groups running Codex, Antigravity
/// and Claude Code would show one model, one repository state and one usage
/// figure between them, following whichever pane was clicked last. So the tab
/// strip reads [workspaceGroupTabsProvider], the surface reads
/// [workspaceGroupActiveTabProvider] and the bar reads
/// [workspaceGroupSessionIdProvider] — all keyed by [groupId].
///
/// **The conversation included**, which it was not at first: it was a view that
/// rendered whatever the Explorer had selected, so a group showing one tab
/// could be reading another tab's transcript — *"the chat view is embeded with
/// terminal but i think it's still responding globally"*. It is named off this
/// group's session now, like everything else here. A selection with no tab to
/// live in is opened **into** one group and stays there
/// ([selectionHostGroupProvider]).
///
/// **We depart from the reference here, deliberately.** VS Code's status bar is
/// one strip across the window, not one per editor group. Ours is per group
/// because it carries *session* state — the model, the account's usage, the
/// delivery stage of the work in that group — and a window-wide row could only
/// ever speak for one of them. What is genuinely about the window stays where
/// VS Code puts it: [ShellStatusBar], one row along the bottom.
///
/// The one thing that stays window-level is which of a session's two renderings
/// is up ([terminalVisibleProvider]): every launcher, approval card and palette
/// command in the app writes it, and at most one conversation is on screen at a
/// time. So the toggle is drawn in every group's bar and answered by the
/// focused one — pressing *Chat* focuses this group first, which is what makes
/// that read as "the conversation opened here".
class _WorkspaceGroup extends ConsumerStatefulWidget {
  const _WorkspaceGroup({
    required this.groupId,
    required this.autoOpenDone,
    super.key,
  });

  /// Null only before the window has a workspace — see [WorkbenchView.build].
  final String? groupId;

  final bool autoOpenDone;

  @override
  ConsumerState<_WorkspaceGroup> createState() => _WorkspaceGroupState();
}

class _WorkspaceGroupState extends ConsumerState<_WorkspaceGroup> {
  /// The session whose **conversation** is mounted, or null when none is.
  ///
  /// The conversation is built only once it has been asked for, and only for
  /// the session it was asked for. An [IndexedStack] builds every child, so
  /// putting the two surfaces in one meant that landing on a session's terminal
  /// — which is what every tap does — also mounted its chat view, and
  /// `sessionChatTranscriptProvider` answers a fresh subscription with a CLI
  /// **store scan** followed by a read and JSON parse of that session's
  /// **whole transcript file**. Two sessions switched back and forth paid that
  /// on every switch, for a surface nobody was looking at: the lag the owner
  /// reported. Measured in `session_switch_cost_test.dart`.
  ///
  /// What the stack was for survives: while the conversation *is* the surface
  /// the user chose, both children stay built, so toggling to the terminal and
  /// back keeps its scroll position. Only the never-asked-for case is dropped —
  /// and a switch to another session is exactly that case, because a different
  /// session's transcript has no scroll position to keep.
  ///
  /// **Mounted is not the same as working**, and the difference is the second
  /// half of this design. A conversation kept alive behind the terminal went on
  /// polling: `sessionChatTranscriptProvider` re-reads and JSON-decodes that
  /// session's *whole* transcript every two seconds whenever the file has moved
  /// — 43.8 MB over 11 637 lines on the owner's machine, 888 ms a tick, moving
  /// constantly, because the agent writing it is the one being typed to. So
  /// the poll is gated on which
  /// surface is in front (`chatTranscriptPollingProvider`, keyed off
  /// [terminalVisibleProvider]): the view keeps its scroll position and its
  /// place in the tree, and stops doing megabytes of work on the UI isolate
  /// under every keystroke. Measured in
  /// `test/app/shell/keystroke_cost_test.dart`.
  String? _conversationFor;
  /// Wired to the labelled Chat half of the bar's toggle.
  ///
  /// This claimed to be "the only write of `false` in the app" and had not
  /// been for some time — the dead-pane card's *Read the conversation* is
  /// another, and `revealConversationForPane` is a third, for text arriving
  /// from the phone. What the claim was protecting still holds and is worth
  /// stating properly: **no ordinary tap opens the conversation.** Every
  /// writer is a labelled, deliberate request for it — which is exactly what
  /// the perf change behind the lazy mount needs, since what it removed was
  /// the transcript read on a tap that did not ask.
  void _showChat() {
    final groupId = widget.groupId;
    if (groupId == null) return;
    _focusThisGroup();
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .showFaceIn(groupId, terminal: false);
  }

  /// Hands this group the keyboard. Cheap to call on every pointer down:
  /// `focusGroup` publishes nothing when the group is already the focused one,
  /// the same guard `focusPane` keeps for a click inside the pane you are in.
  void _focusThisGroup() {
    final groupId = widget.groupId;
    if (groupId == null) return;
    ref.read(terminalSessionsControllerProvider.notifier).focusGroup(groupId);
  }

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    final focused =
        groupId == null || ref.watch(focusedWorkspaceGroupProvider) == groupId;
    final activeTab = groupId == null
        ? null
        : ref.watch(workspaceGroupActiveTabProvider(groupId));

    // No tab of its own is what an empty group *is* — the room a split cleared
    // and nobody has filled yet. It keeps that face even while it holds the
    // keyboard: [_EmptyGroup] is the only way to close a group, and a session
    // drawn over it would take that away with no other way back.
    final empty = groupId != null && activeTab == null;

    final scheme = Theme.of(context).colorScheme;
    final session = empty ? null : _groupSession();
    // With nothing to read, the group is its terminal — an empty middle would
    // be worse than the surface the app is primarily about. Otherwise it is
    // **this group's own face**: a tab owns a session, a terminal view, a chat
    // view and a status strip together, so which of the two faces is up is a
    // property of the group showing that tab. Three agents side by side can
    // show three transcripts at once, which is the point of the layout.
    final onTerminal =
        groupId == null ||
        session == null ||
        ref.watch(terminalVisibleInGroupProvider(groupId));
    // Asked for, or let go of — see [_conversationFor]. Written here rather
    // than in a listener because both inputs are read here and nowhere else,
    // and neither is a provider this may write to.
    if (!onTerminal) {
      _conversationFor = session.id;
    } else if (_conversationFor != session?.id) {
      _conversationFor = null;
    }
    final conversationMounted = session != null && _conversationFor != null;

    return Listener(
      // A press anywhere in the group hands it the keyboard, the way clicking
      // into an editor group does. Translucent, so the pane, the chips and the
      // buttons all still get the pointer.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _focusThisGroup(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabStrip(groupId: groupId, groupFocused: focused),
          const Divider(height: 1),
          Expanded(
            child: ColoredBox(
              color: scheme.surfaceContainerLowest,
              // With two surfaces up, an IndexedStack rather than a branch: the
              // conversation keeps its scroll position while the terminal is up,
              // and — the Loop 26 property — the hidden one paints nothing. With
              // one surface there is nothing to keep alive, so it is not paid
              // for — and until the conversation has been asked for there is no
              // second surface at all ([_conversationFor]).
              child: empty
                  ? _EmptyGroup(groupId: groupId, focused: focused)
                  : session == null
                  ? _TerminalSurface(
                      groupId: groupId,
                      groupFocused: focused,
                      autoOpenDone: widget.autoOpenDone,
                    )
                  : IndexedStack(
                      key: kWorkbenchSurfaces,
                      index: onTerminal ? 0 : 1,
                      children: [
                        _TerminalSurface(
                          session: session,
                          groupId: groupId,
                          groupFocused: focused,
                          autoOpenDone: widget.autoOpenDone,
                        ),
                        // **Named, never read off a window-wide provider.**
                        // This used to be a view that rendered whatever the
                        // Explorer had selected, so a group showing one tab
                        // could be reading another tab's transcript — the
                        // report this group's shape exists to make impossible.
                        if (conversationMounted)
                          if (session.native)
                            SessionTranscriptView(sessionId: session.id)
                          else
                            ImportedSessionView(sessionId: session.id),
                      ],
                    ),
            ),
          ),
          // Outside the stack, because the toggle is the way *back* from the
          // conversation as well as the way to it: hosted on the terminal
          // surface it would be built and unreachable for exactly the surface
          // that has no other way home.
          _SessionBar(
            groupId: groupId,
            session: session,
            onTerminal: onTerminal,
            onChat: _showChat,
            onTerminalView: () {
              _focusThisGroup();
              showTerminalFor(ref, session?.paneId, session?.id);
            },
          ),
        ],
      ),
    );
  }

  /// The session this group is about, as its chrome needs it: a title, whether
  /// it has a pane of ours, and whether it is one of ours at all (imported CLI
  /// sessions have no pane and no live status).
  ///
  /// **This group's own active tab**, and nothing outside the group. A group
  /// nobody is typing into keeps describing its own tab, continuously,
  /// whatever is selected elsewhere — and so does the one that is.
  ///
  /// The Explorer's selection is not an exception to that. One that has a pane
  /// of ours *is* a tab, and opening it is [showTerminalFor] activating that
  /// tab in the group that holds it; one that has no pane has no tab anywhere,
  /// so it is opened **into** a group and only that group draws it — see
  /// [selectionHostGroupProvider] and [_hostedSelection].
  ///
  /// The fallback is deliberately a **read**, not a selection. Writing
  /// `selectedSessionIdProvider` to make the toggle appear would fire the
  /// listener in [WorkbenchView] that opens the session's terminal, so the way
  /// to the conversation would fight the surface the user is already on.
  /// Nothing here writes anything.
  _WorkbenchSession? _groupSession() {
    // The strip draws the session's name and offers the toggle its pane
    // decides. Statuses and permission modes are drawn elsewhere.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.title,
      SessionChangeKind.placement,
    });
    // A pane appearing or ending changes whether this session has a terminal at
    // all, which is what decides whether the strip offers the toggle. Watched
    // rather than read so the strip cannot keep offering a surface that is
    // gone — but only the tab list, because a *process* dying somewhere else
    // cannot change which panes exist, and at a hundred panes that was the
    // common case.
    ref.watch(terminalSessionsControllerProvider.select((s) => s.tabs));
    final groupId = widget.groupId;
    final hosted = _hostedSelection(ref, groupId);
    if (hosted != null) {
      if (!hosted.native) {
        final imported = ref.read(importedSessionDaoProvider).getById(hosted.id);
        return _WorkbenchSession(
          id: hosted.id,
          title: imported?.displayTitle ?? 'Session',
          paneId: null,
          native: false,
        );
      }
      final Session? row = ref.read(sessionDaoProvider).getById(hosted.id);
      return _WorkbenchSession(
        id: hosted.id,
        title: row?.title ?? 'Session',
        paneId: null,
        native: true,
      );
    }
    final sessionId = groupId == null
        ? null
        : ref.watch(workspaceGroupSessionIdProvider(groupId));
    if (sessionId == null) return null;
    final Session? record = ref.read(sessionDaoProvider).getById(sessionId);
    return _WorkbenchSession(
      id: sessionId,
      title: record?.title ?? 'Session',
      paneId: sessionTerminalPane(ref, sessionId),
      native: true,
    );
  }
}

/// The session group [groupId] was asked to show that has no tab to show it in.
///
/// Null for every group but the one the Explorer's selection was opened into
/// ([selectionHostGroupProvider]) — and null there too as soon as that
/// selection has a pane of ours, because a session with a pane *is* a tab and
/// the group holding that tab already draws it. Before the window has a
/// workspace one group stands in for it, so it hosts.
({String id, bool native})? _hostedSelection(WidgetRef ref, String? groupId) {
  final host =
      ref.watch(selectionHostGroupProvider) ??
      ref.watch(focusedWorkspaceGroupProvider);
  if (groupId != null && host != groupId) return null;
  final imported = ref.watch(selectedImportedSessionIdProvider);
  if (imported != null) return (id: imported, native: false);
  final selected = ref.watch(selectedSessionIdProvider);
  if (selected == null) return null;
  // A pane arriving under the selection, or going away, changes the answer.
  ref.watch(terminalTabsProvider);
  ref.watchSessionKinds(const {
    SessionChangeKind.membership,
    SessionChangeKind.placement,
  });
  return sessionTerminalPane(ref, selected) == null
      ? (id: selected, native: true)
      : null;
}

/// The room a workspace split cleared, before anything has been put in it.
///
/// The same face an empty *region* wears one level down, with the drop
/// addressed to a group rather than to a pane — see [EmptyPaneRegion].
class _EmptyGroup extends ConsumerWidget {
  const _EmptyGroup({required this.groupId, required this.focused});

  final String groupId;
  final bool focused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final slot = ref.watch(
      terminalSessionsControllerProvider.select(
        (s) => s.workspace?.groupById(groupId)?.activePaneId,
      ),
    );
    final terminal = TerminalActions(ref);
    return EmptyPaneRegion(
      paneId: slot ?? groupId,
      focused: focused,
      title: 'Empty group',
      closeLabel: 'Close group',
      // A group takes **tabs**; the region one level down takes panes. One word
      // per concept — see [WorkspaceLayout].
      moveLabel: 'Move a tab here…',
      accepts: (TerminalDrag drag) => switch (drag) {
        TabDrag(:final tabId) => sessions.canMoveTabToGroup(tabId, groupId),
        // A pane leaves its split as a tab of its own, which then lands here.
        PaneDrag(:final paneId) => sessions.isPaneInSplit(paneId),
      },
      onDrop: (TerminalDrag drag) {
        switch (drag) {
          case TabDrag(:final tabId):
            sessions.moveTabToGroup(tabId, groupId);
          case PaneDrag(:final paneId):
            final tabId = sessions.movePaneToNewTab(paneId);
            if (tabId != null) sessions.moveTabToGroup(tabId, groupId);
        }
      },
      // Focused first, or the tab would open in whichever group had the
      // keyboard rather than in the one the button is drawn in.
      onNewTerminal: () {
        sessions.focusGroup(groupId);
        terminal.open(terminal.defaultProfile());
      },
      onNewSession: () {
        sessions.focusGroup(groupId);
        NewSessionDialog.show(context);
      },
      onClose: () => sessions.closeGroup(groupId),
      onMoveTabHere: () =>
          TabPicker.show(context, (ref) => tabsMovableToGroup(ref, groupId)),
    );
  }
}
