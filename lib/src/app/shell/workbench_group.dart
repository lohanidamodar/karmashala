part of 'workbench.dart';

/// One **workspace group**: its own tab strip, surface and status bar. Everything
/// reads its *own* group; with two groups, "the window's" is somebody else's.
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
  /// Wired to the labelled Chat half of the bar's toggle. No *ordinary* tap
  /// opens the conversation — every writer of `false` is a deliberate request.
  void _showChat() {
    final groupId = widget.groupId;
    if (groupId == null) return;
    _focusThisGroup();
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .showFaceIn(groupId, terminal: false);
  }

  /// Hands this group the keyboard. Cheap to call on every pointer down:
  /// `focusGroup` publishes nothing when the group is already the focused one.
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

    // No tab of its own is what an empty group *is*. It keeps that face even
    // while it holds the keyboard: [_EmptyGroup] is the only way to close one.
    final empty = groupId != null && activeTab == null;

    final scheme = Theme.of(context).colorScheme;
    final session = empty ? null : _groupSession();
    // With nothing to read the group is its terminal. Which of the two faces is
    // up is a property of *this* group, so three agents can show three at once.
    final onTerminal =
        groupId == null ||
        session == null ||
        ref.watch(terminalVisibleInGroupProvider(groupId));
    // Asked for, or let go of — see [workspaceGroupConversationProvider]. Derived
    // here from both inputs, and written back after the frame.
    final conversationFor = _settleConversation(session?.id, onTerminal);
    final conversationMounted = session != null && conversationFor != null;

    return Listener(
      // A press anywhere in the group hands it the keyboard. Translucent, so
      // the pane, the chips and the buttons all still get the pointer.
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
              // An IndexedStack rather than a branch: the conversation keeps
              // its scroll position, and the hidden one paints nothing.
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
                        // Named, never read off a window-wide provider, or a
                        // group could be reading another tab's transcript.
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
          // conversation: on that surface it would be built and unreachable.
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

  /// The conversation this group keeps mounted now. A provider may not be
  /// written while building, so the stored value catches up after the frame.
  String? _settleConversation(String? sessionId, bool onTerminal) {
    final groupId = widget.groupId;
    final provider = groupId == null
        ? null
        : workspaceGroupConversationProvider(groupId);
    // Listened, not watched: this build already knows the answer, and keeping
    // the provider alive is all the listener is for.
    if (provider != null) ref.listen(provider, (_, _) {});
    final current = provider == null ? null : ref.read(provider);
    final next = nextMountedConversation(
      current: current,
      sessionId: sessionId,
      onTerminal: onTerminal,
    );
    if (provider != null && next != current) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(provider.notifier)
            .settle(sessionId: sessionId, onTerminal: onTerminal);
      });
    }
    return next;
  }

  /// The session this group is about: **this group's own active tab**, and a
  /// *read* — writing the selection would fight the surface the user is on.
  _WorkbenchSession? _groupSession() {
    // The strip draws the session's name and offers the toggle its pane
    // decides. Statuses and permission modes are drawn elsewhere.
    ref.watchSessionKinds(const {
      SessionChangeKind.membership,
      SessionChangeKind.title,
      SessionChangeKind.placement,
    });
    // A pane appearing or ending changes whether this session has a terminal.
    // Only the tab list: a *process* dying cannot change which panes exist.
    ref.watch(terminalSessionsControllerProvider.select((s) => s.tabs));
    final groupId = widget.groupId;
    final hosted = _hostedSelection(ref, groupId);
    if (hosted != null) {
      if (!hosted.native) {
        final imported = ref
            .read(importedSessionDaoProvider)
            .getById(hosted.id);
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
/// Null once that selection has a pane of ours — a session with a pane *is* a tab.
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

/// The room a workspace split cleared, before anything has been put in it — the
/// same face an empty *region* wears one level down ([EmptyPaneRegion]).
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
      onClose: () => closeEditors(context, ref, [
        for (final tab in sessions.tabsInGroup(groupId)) tab.id,
      ], () => sessions.closeGroup(groupId)),
      onMoveTabHere: () =>
          TabPicker.show(context, (ref) => tabsMovableToGroup(ref, groupId)),
    );
  }
}
